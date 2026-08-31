# Managed by vmware-ubuntu-bootstrap.
model = "{{CPA_MODEL_ID}}"
model_provider = "cpa"

[model_providers.cpa]
name = "CPA"
base_url = "{{CPA_BASE_URL}}"
wire_api = "responses"

[model_providers.cpa.auth]
command = "{{CPA_TOKEN_HELPER}}"
timeout_ms = 1000
refresh_interval_ms = 0
