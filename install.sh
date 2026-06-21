#!/usr/bin/env bash
set -euo pipefail

SYNTH_DIR="$HOME/synthea"
PIPE_DIR="$HOME/medical-pipeline"

echo "[1/9] Установка системных пакетов и Docker..."

sudo apt update -y
sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg

if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
fi

sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER" || true
sudo apt install -y openjdk-17-jdk git

echo "[2/9] Клонирование и сборка Synthea..."

if [ ! -d "$SYNTH_DIR" ]; then
  git clone https://github.com/synthetichealth/synthea.git "$SYNTH_DIR"
fi

PROPS="$SYNTH_DIR/src/main/resources/synthea.properties"

sed -i 's|^exporter\.years_of_history.*|exporter.years_of_history = 5|'               "$PROPS"
sed -i 's|^exporter\.split_records\b.*|exporter.split_records = true|'                "$PROPS"
sed -i 's|^exporter\.fhir\.export\b.*|exporter.fhir.export = true|'                   "$PROPS"
sed -i 's|^exporter\.fhir\.bulk_data.*|exporter.fhir.bulk_data = true|'               "$PROPS"
sed -i 's|^exporter\.hospital\.fhir\.export.*|exporter.hospital.fhir.export = true|' "$PROPS"

cd "$SYNTH_DIR"
./gradlew build check -x test

echo "[3/9] Подготовка директории $PIPE_DIR и конфигов..."
mkdir -p "$PIPE_DIR/synthea_output"
cd "$PIPE_DIR"

cat > docker-compose.yml <<'EOF'
version: "3.8"
services:
  namenode:
    image: bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8
    container_name: namenode
    restart: always
    ports: ["9870:9870","9000:9000"]
    environment: [CLUSTER_NAME=medical-cluster]
    env_file: ./config/hadoop.env
    volumes: [hadoop_namenode:/hadoop/dfs/name]
  datanode:
    image: bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java8
    container_name: datanode
    restart: always
    environment: {SERVICE_PRECONDITION: "namenode:9870"}
    env_file: ./config/hadoop.env
    volumes: [hadoop_datanode:/hadoop/dfs/data]
  resourcemanager:
    image: bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java8
    container_name: resourcemanager
    restart: always
    ports: ["8088:8088"]
    environment: {SERVICE_PRECONDITION: "namenode:9000 namenode:9870 datanode:9864"}
    env_file: ./config/hadoop.env
  hive-server:
    image: bde2020/hive:2.3.2-postgresql-metastore
    container_name: hive-server
    restart: always
    ports: ["10000:10000","10002:10002"]
    environment:
      HIVE_CORE_CONF_javax_jdo_option_ConnectionURL: "jdbc:postgresql://hive-metastore-postgresql/metastore"
      SERVICE_PRECONDITION: "hive-metastore:9083"
    env_file: ./config/hadoop.env
    volumes:
      - ./config/hive-site.xml:/opt/hive/conf/hive-site.xml
      - ./config/core-site.xml:/opt/hadoop-3.2.1/etc/hadoop/core-site.xml
  hive-metastore:
    image: bde2020/hive:2.3.2-postgresql-metastore
    container_name: hive-metastore
    restart: always
    environment: {SERVICE_PRECONDITION: "namenode:9000 namenode:9870 datanode:9864 hive-metastore-postgresql:5432"}
    env_file: ./config/hadoop.env
    volumes:
      - ./config/core-site.xml:/opt/hadoop-3.2.1/etc/hadoop/core-site.xml
    command: /opt/hive/bin/hive --service metastore
  hive-metastore-postgresql:
    image: bde2020/hive-metastore-postgresql:2.3.0
    container_name: hive-metastore-postgresql
    volumes: [postgresql_hive:/var/lib/postgresql/data]
  spark-master:
    image: bde2020/spark-master:3.0.0-hadoop3.2
    container_name: spark-master
    ports: ["8080:8080","7077:7077"]
    environment: [INIT_DAEMON_STEP=setup_spark]
    env_file: ./config/hadoop.env
  spark-worker:
    image: bde2020/spark-worker:3.0.0-hadoop3.2
    container_name: spark-worker
    depends_on: [spark-master]
    ports: ["8081:8081"]
    environment: [SPARK_MASTER=spark://spark-master:7077]
    env_file: ./config/hadoop.env
  nifi:
    image: apache/nifi:1.23.2
    container_name: nifi
    ports: ["8443:8443"]
    environment:
      - SINGLE_USER_CREDENTIALS_USERNAME=admin
      - SINGLE_USER_CREDENTIALS_PASSWORD=admin_password123
      - NIFI_JVM_HEAP_INIT=4g
      - NIFI_JVM_HEAP_MAX=8g
    volumes:
      - nifi_data:/opt/nifi/nifi-current/data
      - ~/medical-pipeline/synthea_output:/opt/nifi/input
      - ~/medical-pipeline/config/core-site.xml:/opt/nifi/core-site.xml
    healthcheck:
      test: ["CMD","curl","-f","https://localhost:8443/nifi/","-k"]
      interval: 30s
      timeout: 10s
      retries: 10
  hue:
    image: gethue/hue:latest
    container_name: hue
    ports: ["8888:8888"]
    volumes: [./config/hue.ini:/usr/share/hue/desktop/conf/hue.ini]
    depends_on: [hive-server]
  postgres:
    image: postgres:15
    container_name: postgres-results
    ports: ["5432:5432"]
    environment:
      POSTGRES_USER: medical
      POSTGRES_PASSWORD: medical_pass
      POSTGRES_DB: medical_stats
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ~/medical-pipeline/config/init_postgres.sql:/docker-entrypoint-initdb.d/01_init.sql
      - ~/medical-pipeline/config/init_hue.sql:/docker-entrypoint-initdb.d/02_hue.sql
  dashboard:
    build: ./dashboard
    container_name: dashboard
    ports: ["8090:5000"]
    environment:
      PG_HOST: postgres-results
      PG_DB: medical_stats
      PG_USER: medical
      PG_PASSWORD: medical_pass
      HIVE_HOST: hive-server
      HIVE_PORT: 10000
      HIVE_DB: default
    depends_on: [postgres,hive-server]
    restart: always
volumes:
  hadoop_namenode:
  hadoop_datanode:
  postgresql_hive:
  nifi_data:
  postgres_data:
EOF

echo "[4/9] Загрузка JDBC-драйвера PostgreSQL..."
cd "$PIPE_DIR"
if [ ! -f postgresql-42.7.1.jar ]; then
  wget https://jdbc.postgresql.org/download/postgresql-42.7.1.jar
fi

echo "[5/9] Поднимаем docker-compose стек..."
sudo docker compose up -d
echo "Ждём 60 секунд..."
sleep 60

echo "[6/9] Копируем JDBC в Spark-контейнеры..."
sudo docker cp postgresql-42.7.1.jar spark-master:/spark/jars/ || true
sudo docker cp postgresql-42.7.1.jar spark-worker:/spark/jars/ || true

echo "[7/9] Генерация данных Synthea..."
cd "$SYNTH_DIR"
./run_synthea -p 404 Massachusetts
mkdir -p "$PIPE_DIR/synthea_output"
cp "$SYNTH_DIR/output/fhir/"*.ndjson "$PIPE_DIR/synthea_output/" || true
cd "$PIPE_DIR"

echo "[8/9] Подготовка HDFS и Hive..."
sudo docker exec -u root nifi chmod 777 /opt/nifi/input
sudo docker exec namenode hdfs dfs -mkdir -p \
  /medical/raw/Patient /medical/raw/Condition \
  /medical/raw/Encounter /medical/raw/MedicationRequest \
  /medical/raw/Observation /medical/clean
sudo docker exec namenode hdfs dfs -chmod -R 777 /medical
sudo docker exec namenode hdfs dfs -ls /medical/raw/Patient/ || true
sudo docker cp "$PIPE_DIR/pipeline/create_tables.hql" hive-server:/tmp/create_tables.hql
sudo docker exec hive-server beeline \
  -u "jdbc:hive2://localhost:10000/default;transportMode=binary;auth=noSasl" \
  -f /tmp/create_tables.hql