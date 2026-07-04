# syntax=docker/dockerfile:1.6
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app/rl-scaling-controller/src:/app/rl-signal-sdk/src

WORKDIR /app

# Copy both packages
COPY rl-signal-sdk     /app/rl-signal-sdk
COPY rl-scaling-controller /app/rl-scaling-controller

RUN pip install -e /app/rl-signal-sdk \
 && pip install -e "/app/rl-scaling-controller[k8s]" || pip install -e /app/rl-scaling-controller

EXPOSE 8080

# Liveness/readiness probe target
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/api/v1/status',timeout=2).status==200 else 1)"

CMD ["python", "-m", "rl_scaling_controller.main"]
