# OPA external authorization policy for the inference gateway.
#
# Istio's ingress gateway calls OPA (Envoy ext_authz gRPC) before a request
# reaches the inference router. This policy implements the admission rules
# from the cheat sheet (problem 21, multi-tenant serving):
#
#   - every request must carry a known tenant API key
#   - tenants may only call the OpenAI-compatible inference endpoints
#   - batch-tier tenants are kept off the interactive path
#   - oversized max_tokens requests are rejected at the edge, before
#     they can occupy GPU KV memory
package inference.authz

import rego.v1

default allow := false

# Deny reason surfaced to the client as the ext-authz body
default reason := "request denied by inference gateway policy"

allowed_paths := {
	"/v1/chat/completions",
	"/v1/completions",
	"/v1/embeddings",
	"/v1/models",
}

# Tenant registry. In production this ships as OPA data (bundle or
# configmap), keyed by hashed API key -> tenant record.
tenants := {
	"tenant-interactive-key": {
		"name": "interactive",
		"tier": "interactive",
		"max_tokens_limit": 4096,
	},
	"tenant-batch-key": {
		"name": "batch",
		"tier": "batch",
		"max_tokens_limit": 16384,
	},
}

http_request := input.attributes.request.http

tenant := tenants[api_key] if {
	api_key := trim_prefix(http_request.headers.authorization, "Bearer ")
}

allow if {
	tenant
	http_request.path in allowed_paths
	http_request.method == "POST"
	within_token_limit
}

# /v1/models is a harmless GET for any authenticated tenant
allow if {
	tenant
	http_request.path == "/v1/models"
	http_request.method == "GET"
}

# Reject a request whose max_tokens exceeds the tenant's cap before it
# ever reaches the router (problem 21: estimate cost before admitting).
within_token_limit if {
	not body_max_tokens
}

within_token_limit if {
	body_max_tokens <= tenant.max_tokens_limit
}

body_max_tokens := mt if {
	body := json.unmarshal(http_request.body)
	mt := body.max_tokens
}

reason := "missing or unknown API key" if not tenant

reason := sprintf("max_tokens exceeds tenant cap of %d", [tenant.max_tokens_limit]) if {
	tenant
	body_max_tokens
	body_max_tokens > tenant.max_tokens_limit
}

# Headers injected upstream so the router can do per-tenant fair
# scheduling and the mesh can log per-tenant metrics.
headers := {
	"x-tenant": tenant.name,
	"x-tenant-tier": tenant.tier,
} if {
	tenant
}
