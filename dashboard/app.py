try:
    import psycopg2cffi
    psycopg2cffi.compat.register()
except ImportError:
    pass

from flask import Flask, jsonify, request
from flask_cors import CORS
import psycopg2
import psycopg2.extras
import os
import re

app = Flask(__name__, static_folder="static", static_url_path="")
CORS(app)

PG = dict(
    host=os.getenv("PG_HOST", "postgres"),
    port=int(os.getenv("PG_PORT", 5432)),
    dbname=os.getenv("PG_DB", "medical_stats"),
    user=os.getenv("PG_USER", "medical"),
    password=os.getenv("PG_PASSWORD", "medical_pass"),
)

HIVE_HOST = os.getenv("HIVE_HOST", "hive-server")
HIVE_PORT = int(os.getenv("HIVE_PORT", 10000))
HIVE_DB   = os.getenv("HIVE_DB", "medical")


def pg_query(sql, params=None):
    conn = psycopg2.connect(**PG)
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute(sql, params)
    rows = cur.fetchall()
    conn.close()
    return [dict(r) for r in rows]


def hive_query(sql):
    from pyhive import hive
    conn = hive.connect(
        host=HIVE_HOST,
        port=HIVE_PORT,
        database=HIVE_DB,
        auth="NOSASL",
    )
    cur = conn.cursor()
    cur.execute(sql)
    cols = [d[0].split(".")[-1] for d in cur.description]
    rows = [dict(zip(cols, row)) for row in cur.fetchall()]
    conn.close()
    return rows


def extract_condition_type(name: str) -> str:
    """Extract SNOMED type from parentheses at end: 'Foo (situation)' -> 'situation'"""
    if not name:
        return "unknown"
    m = re.search(r'\(([^)]+)\)\s*$', name.strip())
    return m.group(1).lower() if m else "other"


# ── KPI ────────────────────────────────────────────────────────────────────
@app.route("/api/kpi")
def kpi():
    try:
        patients   = pg_query("SELECT COUNT(DISTINCT patient_id) AS n FROM patients")[0]["n"] or 0
        encounters = pg_query("SELECT COUNT(*) AS n FROM encounters")[0]["n"] or 0
        conditions = pg_query("SELECT COUNT(*) AS n FROM conditions")[0]["n"] or 0
        active     = pg_query("SELECT SUM(active_cases) AS n FROM diagnosis_statistics")[0]["n"] or 0
        try:
            meds = pg_query("SELECT COUNT(*) AS n FROM medications")[0]["n"] or 0
        except Exception:
            meds = 0
        return jsonify({"source": "postgres", "data": {
            "patients": int(patients),
            "encounters": int(encounters),
            "conditions": int(conditions),
            "medications": int(meds),
            "active_cases": int(active),
        }})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e),
                        "data": {"patients": 0, "encounters": 0, "conditions": 0,
                                 "medications": 0, "active_cases": 0}})


# ── Timeline ───────────────────────────────────────────────────────────────
@app.route("/api/timeline")
def timeline():
    try:
        rows = pg_query("""
            SELECT TO_CHAR(CAST(start_date AS DATE), 'YYYY-MM') AS month,
                   COUNT(*) AS count
            FROM encounters
            WHERE start_date >= '2023-01-01'
            GROUP BY 1 ORDER BY 1
        """)
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


# ── Conditions (top chart / table) ─────────────────────────────────────────
@app.route("/api/conditions")
def conditions():
    condition_type = request.args.get("type", "").strip().lower()
    limit = int(request.args.get("limit", 50))

    # Build optional LIKE filter for Hive/Postgres
    type_filter_pg = ""
    type_params = []
    if condition_type and condition_type != "all":
        type_filter_pg = "WHERE diagnosis_name ILIKE %s"
        type_params = [f"%({condition_type})"]

    try:
        hive_type_cond = ""
        if condition_type and condition_type != "all":
            safe = condition_type.replace("'", "''")
            hive_type_cond = f"WHERE lower(diagnosis_name) LIKE '%({safe})'"
        rows = hive_query(f"""
            SELECT diagnosis_name, icd_code,
                   COUNT(DISTINCT patient_id) AS patients,
                   COUNT(*) AS total
            FROM conditions
            {hive_type_cond}
            GROUP BY diagnosis_name, icd_code
            ORDER BY patients DESC
            LIMIT {limit}
        """)
        for r in rows:
            r["condition_type"] = extract_condition_type(r.get("diagnosis_name", ""))
        return jsonify({"source": "hive", "data": rows})
    except Exception:
        pass

    try:
        sql = f"""
            SELECT diagnosis_name, icd_code,
                   unique_patients AS patients,
                   total_cases AS total,
                   active_cases
            FROM diagnosis_statistics
            {type_filter_pg}
            ORDER BY unique_patients DESC
            LIMIT {limit}
        """
        rows = pg_query(sql, type_params if type_params else None)
        for r in rows:
            r["condition_type"] = extract_condition_type(r.get("diagnosis_name", ""))
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


# ── Condition types list ───────────────────────────────────────────────────
@app.route("/api/conditions/types")
def condition_types():
    try:
        rows = hive_query("""
            SELECT DISTINCT diagnosis_name FROM conditions
            WHERE diagnosis_name IS NOT NULL
        """)
        names = [r.get("diagnosis_name", "") for r in rows]
    except Exception:
        try:
            rows = pg_query("""
                SELECT DISTINCT diagnosis_name FROM diagnosis_statistics
                WHERE diagnosis_name IS NOT NULL
            """)
            names = [r.get("diagnosis_name", "") for r in rows]
        except Exception as e:
            return jsonify({"source": "error", "error": str(e), "data": []})

    types = sorted(set(extract_condition_type(n) for n in names if n))
    return jsonify({"source": "postgres", "data": types})


# ── Patients list ──────────────────────────────────────────────────────────
@app.route("/api/patients")
def patients():
    page      = max(1, int(request.args.get("page", 1)))
    limit     = min(100, int(request.args.get("limit", 25)))
    search    = request.args.get("q", "").strip()
    gender    = request.args.get("gender", "").strip().lower()
    age_group = (request.args.get("age_group") or request.args.get("agegroup") or "").strip()
    offset    = (page - 1) * limit

    filters = []
    params  = []
    if search:
        filters.append("(patient_id ILIKE %s OR city ILIKE %s OR state ILIKE %s)")
        params += [f"%{search}%", f"%{search}%", f"%{search}%"]
    if gender:
        # FHIR stores 'male'/'female', frontend may send 'M'/'F' — normalise both sides
        filters.append("LOWER(gender) = %s")
        params.append(gender)
    if age_group:
        filters.append("age_group = %s")
        params.append(age_group)

    where = ("WHERE " + " AND ".join(filters)) if filters else ""

    # Deduplicate via CTE (Spark JDBC overwrite drops PK constraints → duplicates)
    # params passed twice: once for COUNT subquery, once for paginated SELECT
    dedup_cte = f"""
        WITH deduped AS (
            SELECT DISTINCT ON (patient_id)
                patient_id, gender, birth_year, age_group, state, city
            FROM patients
            {where}
            ORDER BY patient_id
        )
    """
    try:
        p = params if params else None
        total = pg_query(
            f"SELECT COUNT(*) AS n FROM (SELECT DISTINCT patient_id FROM patients {where}) t",
            p
        )[0]["n"]
        rows = pg_query(
            f"""{dedup_cte}
            SELECT patient_id, gender, birth_year, age_group, state, city
            FROM deduped
            ORDER BY patient_id
            LIMIT {limit} OFFSET {offset}
            """,
            p
        )
        return jsonify({
            "source": "postgres",
            "total": int(total),
            "page": page,
            "limit": limit,
            "data": rows,
        })
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "total": 0, "data": []})


# ── Patient encounters ─────────────────────────────────────────────────────
@app.route("/api/patients/<patient_id>/encounters")
def patient_encounters(patient_id):
    try:
        rows = pg_query("""
            SELECT encounter_id, encounter_class, encounter_type, start_date, end_date
            FROM encounters WHERE patient_id = %s ORDER BY start_date DESC LIMIT 20
        """, [patient_id])
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


# ── Patient conditions ─────────────────────────────────────────────────────
@app.route("/api/patients/<patient_id>/conditions")
def patient_conditions(patient_id):
    try:
        rows = hive_query(f"""
            SELECT diagnosis_name, icd_code, clinical_status, onset_date
            FROM conditions WHERE patient_id = '{patient_id.replace("'","''")}'
            ORDER BY onset_date DESC LIMIT 30
        """)
        return jsonify({"source": "hive", "data": rows})
    except Exception:
        pass
    try:
        rows = pg_query("""
            SELECT diagnosis_name, icd_code, age_group, cases
            FROM conditions WHERE icd_code IN (
                SELECT icd_code FROM diagnosis_statistics LIMIT 5
            ) LIMIT 20
        """)
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


# ── Demographics ───────────────────────────────────────────────────────────
@app.route("/api/gender")
def gender():
    try:
        rows = pg_query("SELECT gender, count, percentage FROM demographics_gender ORDER BY count DESC")
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})

@app.route("/api/patients/genders")
def patient_genders():
    """Returns distinct gender values actually stored in patients table."""
    try:
        rows = pg_query("SELECT DISTINCT LOWER(gender) AS gender FROM patients WHERE gender IS NOT NULL ORDER BY 1")
        return jsonify({"source": "postgres", "data": [r["gender"] for r in rows]})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


@app.route("/api/age")
def age():
    try:
        rows = pg_query("""
            SELECT age_group, count FROM demographics_age_group
            ORDER BY CASE age_group
                WHEN '0-18'  THEN 1 WHEN '19-25' THEN 2
                WHEN '26-50' THEN 3 WHEN '51-75' THEN 4
                WHEN '75+'   THEN 5 ELSE 6 END
        """)
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


@app.route("/api/geography")
def geography():
    try:
        rows = pg_query("SELECT state, patient_count FROM demographics_geography ORDER BY patient_count DESC")
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


@app.route("/api/diagnoses/by-gender")
def diagnoses_by_gender():
    try:
        rows = pg_query("""
            SELECT gender, diagnosis_name, icd_code, cases AS case_count
            FROM diagnosis_by_gender ORDER BY cases DESC LIMIT 20
        """)
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


@app.route("/api/diagnoses/by-age")
def diagnoses_by_age():
    try:
        rows = pg_query("""
            SELECT age_group, diagnosis_name, icd_code, cases AS case_count
            FROM diagnosis_by_age_group ORDER BY cases DESC LIMIT 20
        """)
        return jsonify({"source": "postgres", "data": rows})
    except Exception as e:
        return jsonify({"source": "error", "error": str(e), "data": []})


# ── System status ──────────────────────────────────────────────────────────
@app.route("/api/status")
def status():
    components = []
    try:
        pg_query("SELECT 1")
        components.append({"name": "PostgreSQL", "status": "ok", "detail": "medical_stats"})
    except Exception as e:
        components.append({"name": "PostgreSQL", "status": "error", "detail": str(e)[:80]})
    try:
        hive_query("SHOW DATABASES")
        components.append({"name": "Hive", "status": "ok", "detail": "hive-server:10000"})
    except Exception as e:
        components.append({"name": "Hive", "status": "error", "detail": str(e)[:80]})
    return jsonify(components)


@app.route("/api/health")
def health():
    try:
        pg_query("SELECT 1")
        return jsonify({"status": "ok", "db": "connected"})
    except Exception as e:
        return jsonify({"status": "error", "db": str(e)}), 500


@app.route("/")
def index():
    return app.send_static_file("index.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
