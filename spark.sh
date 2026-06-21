#!/usr/bin/env bash
set -euo pipefail

SYNTH_DIR="$HOME/synthea"
PIPE_DIR="$HOME/medical-pipeline"

echo "[9/9] Запуск Spark-пайплайнов..."
sudo docker cp "$PIPE_DIR/pipeline/spark_pipeline.py" spark-master:/tmp/spark_pipeline.py
sudo docker exec spark-master env PYSPARK_PYTHON=python3 /spark/bin/spark-submit \
    --master spark://spark-master:7077 \
    --conf spark.executor.memory=6g \
    --conf spark.driver.memory=2g \
    --jars /opt/spark/jars/postgresql-42.7.1.jar \
    /tmp/spark_pipeline.py

sudo docker cp "$PIPE_DIR/pipeline/medication.py" spark-master:/tmp/medication.py
sudo docker exec spark-master env PYSPARK_PYTHON=python3 /spark/bin/spark-submit \
    --master spark://spark-master:7077 \
    --conf spark.executor.memory=4g \
    --conf spark.driver.memory=2g \
    --jars /opt/spark/jars/postgresql-42.7.1.jar \
    /tmp/medication.py

echo ""
echo "=== Готово ==="
echo "  NiFi:         https://localhost:8443/nifi  (admin / admin_password123)"
echo "  Hue:          http://localhost:8888"
echo "  Dashboard:    http://localhost:8090"
echo "  HDFS Web UI:  http://localhost:9870"
echo "  Spark UI:     http://localhost:8080"