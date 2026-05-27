FROM python:3.13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    build-essential \
    libpq-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN pip install uv

ENV APP_ENV=development
ENV DATABASE_URL=postgresql://localhost:5432/myapp

WORKDIR /app
COPY requirements.txt .
RUN uv pip install --system -r requirements.txt
COPY . .

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
