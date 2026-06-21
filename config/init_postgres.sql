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