FROM ubuntu:22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www
COPY script.sh entrypoint.sh /usr/local/bin/
RUN sed -i 's/\r$//' /usr/local/bin/script.sh /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/script.sh /usr/local/bin/entrypoint.sh

ENV PYTHONUNBUFFERED=1
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/', timeout=2)" || exit 1
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
