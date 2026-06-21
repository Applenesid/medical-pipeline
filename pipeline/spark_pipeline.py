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
