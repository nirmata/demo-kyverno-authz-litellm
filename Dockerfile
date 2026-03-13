FROM docker.litellm.ai/berriai/litellm-database:main-stable
COPY custom_auth.py /etc/litellm/custom_auth.py
