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