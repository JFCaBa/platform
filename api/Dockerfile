FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN useradd --system --uid 10001 --no-create-home app
WORKDIR /srv
COPY platform_api ./platform_api
USER app
EXPOSE 8510
HEALTHCHECK --interval=60s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8510/health', timeout=4)"
CMD ["python", "-m", "platform_api.server"]
