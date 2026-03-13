FROM docker.litellm.ai/berriai/litellm:main-stable
# Install deps required by custom_auth.py (httpx for outbound HTTP to authz service)
COPY requirements-custom-auth.txt .
RUN pip install --no-cache-dir -r requirements-custom-auth.txt