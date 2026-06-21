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

cat > hadoop.env <<'EOF'
CORE_CONF_fs_defaultFS=hdfs://namenode:9000
CORE_CONF_hadoop_http_staticuser_user=root
HDFS_CONF_dfs_replication=1
HDFS_CONF_dfs_webhdfs_enabled=true
YARN_CONF_yarn_log___aggregation___enable=true
YARN_CONF_yarn_resourcemanager_hostname=resourcemanager
HIVE_SITE_CONF_javax_jdo_option_ConnectionURL=jdbc:postgresql://hive-metastore-postgresql/metastore
HIVE_SITE_CONF_javax_jdo_option_ConnectionDriverName=org.postgresql.Driver
HIVE_SITE_CONF_javax_jdo_option_ConnectionUserName=hive
HIVE_SITE_CONF_javax_jdo_option_ConnectionPassword=hive
HIVE_SITE_CONF_datanucleus_autoCreateSchema=false
HIVE_SITE_CONF_hive_metastore_uris=thrift://hive-metastore:9083
CORE_CONF_hadoop_proxyuser_hue_hosts=*
CORE_CONF_hadoop_proxyuser_hue_groups=*
CORE_CONF_hadoop_proxyuser_root_hosts=*
CORE_CONF_hadoop_proxyuser_root_groups=*
EOF

cat > core-site.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://namenode:9000</value>
  </property>
</configuration>
EOF

cat > hive-site.xml <<'EOF'
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>hive.metastore.uris</name>
    <value>thrift://hive-metastore:9083</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>jdbc:postgresql://hive-metastore-postgresql/metastore</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>org.postgresql.Driver</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionUserName</name>
    <value>hive</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionPassword</name>
    <value>hive</value>
  </property>
  <property>
    <name>datanucleus.autoCreateSchema</name>
    <value>false</value>
  </property>
  <property>
    <name>hive.server2.enable.doAs</name>
    <value>false</value>
  </property>
  <property>
    <name>hive.server2.authentication</name>
    <value>NOSASL</value>
  </property>
  <!-- FIX: явно задаём HDFS как дефолтную ФС — без этого Hive не видит HDFS -->
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://namenode:9000</value>
  </property>
</configuration>
EOF

cat > hue.ini <<'EOF'
[desktop]
secret_key=kasdlfjknasdfl3hbaksk3bwkasdfkasdfba23asdf
http_host=0.0.0.0
http_port=8888
time_zone=America/Los_Angeles
django_debug_mode=false
http_500_debug_mode=false
app_blacklist=search,hbase,security
use_cherrypy_server=false
gunicorn_work_class=sync
gunicorn_number_of_workers=1

[[database]]
engine=postgresql_psycopg2
host=postgres-results
port=5432
user=hue
password=hue_pass
name=hue_db

[beeswax]
hive_server_host=hive-server
hive_server_port=10000
thrift_version=7
use_sasl=false
auth_username=root
server_conn_timeout=120

[notebook]
[[interpreters]]
[[[hive]]]
name=Hive
interface=hiveserver2

[hadoop]
[[hdfs_clusters]]
[[[default]]]
fs_defaultfs=hdfs://namenode:9000
webhdfs_url=http://namenode:9870/webhdfs/v1

[dashboard]
has_sql_enabled=true
EOF

cat > init_postgres.sql <<'EOF'
CREATE TABLE IF NOT EXISTS diagnosis_statistics (
    icd_code         VARCHAR(20)    NOT NULL,
    diagnosis_name   TEXT,
    total_cases      INTEGER        DEFAULT 0,
    unique_patients  INTEGER        DEFAULT 0,
    active_cases     INTEGER        DEFAULT 0,
    PRIMARY KEY (icd_code)
);
CREATE TABLE IF NOT EXISTS demographics_gender (
    gender      VARCHAR(20) NOT NULL PRIMARY KEY,
    count       INTEGER     DEFAULT 0,
    percentage  NUMERIC(5,2)
);
CREATE TABLE IF NOT EXISTS demographics_age_group (
    age_group   VARCHAR(20) NOT NULL PRIMARY KEY,
    count       INTEGER     DEFAULT 0
);
CREATE TABLE IF NOT EXISTS demographics_geography (
    state          VARCHAR(50) NOT NULL PRIMARY KEY,
    patient_count  INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS diagnosis_by_gender (
    id              SERIAL PRIMARY KEY,
    icd_code        VARCHAR(20),
    diagnosis_name  TEXT,
    gender          VARCHAR(20),
    cases           INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS diagnosis_by_age_group (
    id              SERIAL PRIMARY KEY,
    icd_code        VARCHAR(20),
    diagnosis_name  TEXT,
    age_group       VARCHAR(20),
    cases           INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS pipeline_runs (
    run_id       SERIAL PRIMARY KEY,
    run_time     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    patients_processed  INTEGER,
    conditions_processed INTEGER,
    status       VARCHAR(20)
);
CREATE TABLE IF NOT EXISTS conditions (
    id              SERIAL PRIMARY KEY,
    icd_code        VARCHAR(20),
    diagnosis_name  TEXT,
    age_group       VARCHAR(20),
    cases           INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS encounters (
    encounter_id    VARCHAR(64) PRIMARY KEY,
    patient_id      VARCHAR(64),
    encounter_class VARCHAR(50),
    encounter_type  VARCHAR(100),
    start_date      VARCHAR(30),
    end_date        VARCHAR(30)
);
CREATE TABLE IF NOT EXISTS patients (
    patient_id      VARCHAR(64) PRIMARY KEY,
    gender          VARCHAR(10),
    birth_year      VARCHAR(4),
    age_group       VARCHAR(20),
    state           VARCHAR(50),
    city            VARCHAR(100)
);
CREATE TABLE IF NOT EXISTS medications (
    med_id         VARCHAR(64) PRIMARY KEY,
    patient_id     VARCHAR(64) NOT NULL,
    encounter_id   VARCHAR(64),
    start_date     VARCHAR(30),
    end_date       VARCHAR(30),
    drug_code      VARCHAR(50),
    drug_name      VARCHAR(255),
    dose           VARCHAR(100),
    route          VARCHAR(50),
    status         VARCHAR(50)
);
CREATE INDEX IF NOT EXISTS idx_diag_stats_code    ON diagnosis_statistics (icd_code);
CREATE INDEX IF NOT EXISTS idx_diag_gender_code   ON diagnosis_by_gender (icd_code, gender);
CREATE INDEX IF NOT EXISTS idx_diag_age_code      ON diagnosis_by_age_group (icd_code, age_group);
EOF

# =========================================================
# FIX 1b: hue_db создаётся в ОТДЕЛЬНОМ файле — CREATE DATABASE
# нельзя выполнять внутри транзакции (тот же .sql-файл).
# entrypoint PostgreSQL выполняет файлы из initdb.d по порядку,
# каждый файл в отдельной сессии.
# =========================================================
cat > init_hue.sql <<'EOF'
CREATE DATABASE hue_db;
CREATE USER hue WITH PASSWORD 'hue_pass';
GRANT ALL PRIVILEGES ON DATABASE hue_db TO hue;
ALTER DATABASE hue_db OWNER TO hue;
\connect hue_db
GRANT ALL ON SCHEMA public TO hue;
GRANT CREATE ON SCHEMA public TO hue;
EOF

cat > create_tables.hql <<'EOF'
CREATE DATABASE IF NOT EXISTS medical;
USE medical;
CREATE EXTERNAL TABLE IF NOT EXISTS patients (
    patient_id  STRING, gender STRING, birth_year STRING,
    age_group   STRING, state  STRING, city        STRING
)
STORED AS PARQUET LOCATION 'hdfs://namenode:9000/medical/clean/patients/';
CREATE EXTERNAL TABLE IF NOT EXISTS conditions (
    condition_id STRING, patient_id STRING, icd_code STRING,
    diagnosis_name STRING, clinical_status STRING, onset_date STRING
)
STORED AS PARQUET LOCATION 'hdfs://namenode:9000/medical/clean/conditions/';
CREATE EXTERNAL TABLE IF NOT EXISTS encounters (
    encounter_id STRING, patient_id STRING, encounter_class STRING,
    encounter_type STRING, start_date STRING, end_date STRING
)
STORED AS PARQUET LOCATION 'hdfs://namenode:9000/medical/clean/encounters/';
EOF

cat > spark_pipeline.py <<'EOF'
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.functions import sha2

spark = SparkSession.builder \
    .appName("MedicalDataPipeline") \
    .master("spark://spark-master:7077") \
    .config("spark.jars", "/opt/spark/jars/postgresql-42.7.1.jar") \
    .config("spark.hadoop.fs.defaultFS", "hdfs://namenode:9000") \
    .getOrCreate()
spark.sparkContext.setLogLevel("WARN")

HDFS_RAW   = "hdfs://namenode:9000/medical/raw"
HDFS_CLEAN = "hdfs://namenode:9000/medical/clean"
PG_URL     = "jdbc:postgresql://postgres-results:5432/medical_stats"
PG_PROPS   = {"user": "medical", "password": "medical_pass", "driver": "org.postgresql.Driver"}

patients_raw = spark.read.json(f"{HDFS_RAW}/Patient/")
patients = patients_raw.select(
    sha2(F.col("id"), 256).alias("patient_id"),
    F.col("gender"),
    F.substring(F.col("birthDate"), 1, 4).alias("birth_year"),
    F.col("address")[0]["state"].alias("state"),
    F.col("address")[0]["city"].alias("city"),
).filter(F.col("patient_id").isNotNull())
patients = patients.withColumn("age_group",
    F.when(F.col("birth_year").cast("int") >= 2000, "0-25")
     .when(F.col("birth_year").cast("int") >= 1975, "26-50")
     .when(F.col("birth_year").cast("int") >= 1950, "51-75")
     .otherwise("75+"))
patients.write.mode("overwrite").parquet(f"{HDFS_CLEAN}/patients/")

conditions = spark.read.json(f"{HDFS_RAW}/Condition/").select(
    F.col("id").alias("condition_id"),
    sha2(F.split(F.col("subject.reference"), "/")[1], 256).alias("patient_id"),
    F.col("code.coding")[0]["code"].alias("icd_code"),
    F.col("code.coding")[0]["display"].alias("diagnosis_name"),
    F.col("clinicalStatus.coding")[0]["code"].alias("clinical_status"),
    F.col("onsetDateTime").alias("onset_date"),
).filter(F.col("icd_code").isNotNull())
conditions.write.mode("overwrite").parquet(f"{HDFS_CLEAN}/conditions/")

encounters = spark.read.json(f"{HDFS_RAW}/Encounter/").select(
    F.col("id").alias("encounter_id"),
    sha2(F.split(F.col("subject.reference"), "/")[1], 256).alias("patient_id"),
    F.col("class.code").alias("encounter_class"),
    F.col("type")[0]["coding"][0]["display"].alias("encounter_type"),
    F.col("period.start").alias("start_date"),
    F.col("period.end").alias("end_date"),
)
encounters.write.mode("overwrite").parquet(f"{HDFS_CLEAN}/encounters/")

cond = spark.read.parquet(f"{HDFS_CLEAN}/conditions/")
diag_stats = cond.groupBy("icd_code", "diagnosis_name").agg(
    F.count("*").alias("total_cases"),
    F.countDistinct("patient_id").alias("unique_patients"),
    F.sum(F.when(F.col("clinical_status") == "active", 1).otherwise(0)).alias("active_cases")
).orderBy(F.desc("total_cases")).limit(50)
diag_stats.write.mode("overwrite").parquet(f"{HDFS_CLEAN}/stats/diagnosis_stats/")

pts = spark.read.parquet(f"{HDFS_CLEAN}/patients/")
gender_stats = pts.groupBy("gender").agg(F.count("*").alias("count")) \
    .withColumn("percentage", F.round(F.col("count") / pts.count() * 100, 2))
age_stats = pts.groupBy("age_group").agg(F.count("*").alias("count")).orderBy("age_group")
geo_stats  = pts.groupBy("state").agg(F.count("*").alias("patient_count")).orderBy(F.desc("patient_count"))

cwd = cond.join(pts.select("patient_id", "gender", "age_group", "state"), on="patient_id", how="left")
diag_by_gender = cwd.groupBy("icd_code", "diagnosis_name", "gender").agg(F.count("*").alias("cases")).orderBy(F.desc("cases"))
diag_by_age    = cwd.groupBy("icd_code", "diagnosis_name", "age_group").agg(F.count("*").alias("cases")).orderBy("icd_code", "age_group")

def pg(df, t):
    df.write.mode("overwrite").jdbc(url=PG_URL, table=t, properties=PG_PROPS)
    print(f"'{t}': {df.count()} rows")

pg(diag_stats,     "diagnosis_statistics")
pg(gender_stats,   "demographics_gender")
pg(age_stats,      "demographics_age_group")
pg(geo_stats,      "demographics_geography")
pg(diag_by_gender, "diagnosis_by_gender")
pg(diag_by_age,    "diagnosis_by_age_group")
pg(spark.read.parquet(f"{HDFS_CLEAN}/conditions/"),  "conditions")
pg(spark.read.parquet(f"{HDFS_CLEAN}/patients/"),    "patients")
pg(spark.read.parquet(f"{HDFS_CLEAN}/encounters/"),  "encounters")
spark.stop()
print("Pipeline complete.")
EOF

cat > medication.py <<'EOF'
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import StringType

HDFS_RAW  = "hdfs://namenode:9000/medical/raw/MedicationRequest"
HDFS_OUT  = "hdfs://namenode:9000/medical/clean/medications"
PG_URL    = "jdbc:postgresql://postgres-results:5432/medical_stats"
PG_PROPS  = {"user": "medical", "password": "medical_pass", "driver": "org.postgresql.Driver"}

spark = SparkSession.builder.appName("MedicationsToPostgres") \
    .config("spark.sql.shuffle.partitions", "8").getOrCreate()
spark.sparkContext.setLogLevel("WARN")

meds = (spark.read.json(HDFS_RAW)
    .withColumn("med_id", F.col("id"))
    .withColumn("patient_id",   F.regexp_replace(F.col("subject.reference"),  "^Patient/",   ""))
    .withColumn("encounter_id", F.regexp_replace(F.col("encounter.reference"), "^Encounter/", ""))
    .withColumn("drug_code", F.col("medicationCodeableConcept.coding")[0]["code"].cast(StringType()))
    .withColumn("drug_name", F.col("medicationCodeableConcept.coding")[0]["display"].cast(StringType()))
    .withColumn("start_date", F.to_date(F.col("authoredOn")).cast(StringType()))
    .withColumn("status", F.col("status"))
    .withColumn("dose",  F.col("dosageInstruction")[0]["text"].cast(StringType()))
    .withColumn("route", F.lit(""))
    .select("med_id","patient_id","encounter_id","start_date","drug_code","drug_name","dose","route","status")
    .dropDuplicates(["med_id"]).filter(F.col("med_id").isNotNull()))

meds.write.mode("overwrite").parquet(HDFS_OUT)
meds.write.jdbc(PG_URL, "medications", mode="overwrite", properties=PG_PROPS)
print(f"Done: {meds.count()} rows")
spark.stop()
EOF

cat > docker-compose.yml <<'EOF'
version: "3.8"
services:
  namenode:
    image: bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8
    container_name: namenode
    restart: always
    ports: ["9870:9870","9000:9000"]
    environment: [CLUSTER_NAME=medical-cluster]
    env_file: ./hadoop.env
    volumes: [hadoop_namenode:/hadoop/dfs/name]
  datanode:
    image: bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java8
    container_name: datanode
    restart: always
    environment: {SERVICE_PRECONDITION: "namenode:9870"}
    env_file: ./hadoop.env
    volumes: [hadoop_datanode:/hadoop/dfs/data]
  resourcemanager:
    image: bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java8
    container_name: resourcemanager
    restart: always
    ports: ["8088:8088"]
    environment: {SERVICE_PRECONDITION: "namenode:9000 namenode:9870 datanode:9864"}
    env_file: ./hadoop.env
  hive-server:
    image: bde2020/hive:2.3.2-postgresql-metastore
    container_name: hive-server
    restart: always
    ports: ["10000:10000","10002:10002"]
    environment:
      HIVE_CORE_CONF_javax_jdo_option_ConnectionURL: "jdbc:postgresql://hive-metastore-postgresql/metastore"
      SERVICE_PRECONDITION: "hive-metastore:9083"
    env_file: ./hadoop.env
    volumes:
      - ./hive-site.xml:/opt/hive/conf/hive-site.xml
      # FIX: монтируем core-site.xml чтобы hive-server видел HDFS
      - ./core-site.xml:/opt/hadoop-3.2.1/etc/hadoop/core-site.xml
  hive-metastore:
    image: bde2020/hive:2.3.2-postgresql-metastore
    container_name: hive-metastore
    restart: always
    environment: {SERVICE_PRECONDITION: "namenode:9000 namenode:9870 datanode:9864 hive-metastore-postgresql:5432"}
    env_file: ./hadoop.env
    # FIX: монтируем core-site.xml в metastore
    volumes:
      - ./core-site.xml:/opt/hadoop-3.2.1/etc/hadoop/core-site.xml
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
    env_file: ./hadoop.env
  spark-worker:
    image: bde2020/spark-worker:3.0.0-hadoop3.2
    container_name: spark-worker
    depends_on: [spark-master]
    ports: ["8081:8081"]
    environment: [SPARK_MASTER=spark://spark-master:7077]
    env_file: ./hadoop.env
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
      - ~/medical-pipeline/core-site.xml:/opt/nifi/core-site.xml
    healthcheck:
      test: ["CMD","curl","-f","https://localhost:8443/nifi/","-k"]
      interval: 30s
      timeout: 10s
      retries: 10
  hue:
    image: gethue/hue:latest
    container_name: hue
    ports: ["8888:8888"]
    volumes: [./hue.ini:/usr/share/hue/desktop/conf/hue.ini]
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
      # FIX: разбиваем на два файла — 01_ создаёт таблицы, 02_ создаёт hue_db
      # (CREATE DATABASE нельзя запускать в транзакции — нужна отдельная сессия)
      - ~/medical-pipeline/init_postgres.sql:/docker-entrypoint-initdb.d/01_init.sql
      - ~/medical-pipeline/init_hue.sql:/docker-entrypoint-initdb.d/02_hue.sql
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
if [ -f "$HOME/dashboard.tar.gz" ] && [ ! -d "$PIPE_DIR/dashboard" ]; then
  mkdir -p "$PIPE_DIR/dashboard"
  tar -xzf "$HOME/dashboard.tar.gz" -C "$PIPE_DIR"
else
  echo "dashboard.tar.gz не найден, шаг пропущен."
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
sudo docker cp "$PIPE_DIR/create_tables.hql" hive-server:/tmp/create_tables.hql
sudo docker exec hive-server beeline \
  -u "jdbc:hive2://localhost:10000/default;transportMode=binary;auth=noSasl" \
  -f /tmp/create_tables.hql