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