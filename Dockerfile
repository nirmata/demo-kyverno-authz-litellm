FROM docker.litellm.ai/berriai/litellm-database:main-stable
RUN pip install --no-cache-dir "PyJWT[crypto]"
# custom_auth.py is supplied at runtime via a Kubernetes ConfigMap volume (see litellm-helm).
