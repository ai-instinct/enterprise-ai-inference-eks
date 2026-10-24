package inference.authz

import rego.v1

default allow := false

default reason := "request denied by inference gateway policy"

allowed_paths := {
	"/v1/chat/completions",
	"/v1/completions",
	"/v1/embeddings",
	"/v1/models",
}

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

allow if {
	tenant
	http_request.path == "/v1/models"
	http_request.method == "GET"
}

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

headers := {
	"x-tenant": tenant.name,
	"x-tenant-tier": tenant.tier,
} if {
	tenant
}
