FROM python:3.10-slim-bookworm

WORKDIR /app
COPY wheels/ ./wheels/
COPY requirements.txt .
RUN pip install --no-cache-dir --no-index --find-links=./wheels -r requirements.txt

COPY app.py .
COPY static/ ./static/

EXPOSE 5000
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:5000", "--timeout", "60", "app:app"]
