FROM docker.litellm.ai/berriai/litellm-database:main-stable
RUN pip install --no-cache-dir "PyJWT[crypto]"
COPY custom_auth.py /etc/litellm/custom_auth.py
