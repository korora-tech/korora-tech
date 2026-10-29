package cuenv

import (
	"github.com/cuenv/cuenv/schema"
	"registry.terraform.io/cloudflare/cloudflare:cloudflare_provider"
	"registry.terraform.io/cloudflare/cloudflare/resources/cloudflare_account_token"
	"registry.terraform.io/infisical/infisical:infisical_provider"
	"registry.terraform.io/infisical/infisical/resources/infisical_secret"
)

schema.#Project

name: "korora-tech"

let _accountId = "0aeb879de8e3cdde5fb3d413025222ce"

let _zoneId = "8616ab6882fb4d01da13eb379f406f9a" // korora.tech

let _infisicalProjectId = "7c237571-6f1c-409d-b5e4-ea814d434217"

// Root (all-access) Cloudflare token. Only used to provision the scoped
// deploy token below and to reach the D1 state database.
_cloudflareRootToken: schema.#OnePasswordRef & {ref: "op://Employee/Cloudflare/api-tokens/all-access"}

let _infrastructure = [{allowInfrastructure: ["plan", "apply", "import", "destroy"]}]

env: {
	CLOUDFLARE_ACCOUNT_ID: _accountId
	CLOUDFLARE_API_TOKEN: {
		value:    _cloudflareRootToken
		policies: _infrastructure
	}
	INFISICAL_UNIVERSAL_AUTH_CLIENT_ID: {
		value: schema.#OnePasswordRef & {ref: "op://Employee/Infisical/machine-identity/client-id"}
		policies: _infrastructure
	}
	INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET: {
		value: schema.#OnePasswordRef & {ref: "op://Employee/Infisical/machine-identity/client-secret"}
		policies: _infrastructure
	}

}

infrastructure: {
	// Shared with rawkode-academy; state is keyed by module path.
	state: d1: {
		accountId:  _accountId
		databaseId: "ceacd475-c672-4a64-8f4c-cbd454c08135"
		token:      _cloudflareRootToken
	}

	providers: {
		cloudflare: cloudflare_provider.#Provider
		infisical:  infisical_provider.#Provider
	}

	resources: {
		deploy_token: cloudflare_account_token.#Resource & {
			configuration: {
				account_id: _accountId
				name:       "korora-tech"
				// The provider returns policies ordered by resource and permission
				// groups sorted by ID; match that so the result after create is
				// consistent with the plan.
				policies: [
					{
						effect: "allow"
						permission_groups: [
							{id: "c1fde68c7bcc44588cbb6ddbc16d6480"}, // Account Settings Read
							{id: "e086da7e2179491d91ee5f35b3ca210a"}, // Workers Scripts Write
						]
						resources: "{\"com.cloudflare.api.account.\(_accountId)\":\"*\"}"
					},
					{
						effect: "allow"
						permission_groups: [
							{id: "28f4b596e7d643029c524985477ae49a"}, // Workers Routes Write
							{id: "4755a26eedb94da69e1066d98aa820be"}, // DNS Write
							{id: "c8fed203ed3043cba015a93ad1616f1f"}, // Zone Read
						]
						resources: "{\"com.cloudflare.api.account.zone.\(_zoneId)\":\"*\"}"
					},
				]
			}
		}

		deploy_token_secret: infisical_secret.#Resource & {
			configuration: {
				workspace_id: _infisicalProjectId
				env_slug:     "production"
				folder_path:  "/"
				name:         "CLOUDFLARE_API_TOKEN"
				value: schema.#InfrastructureOutputReference & {
					fromResource: "cloudflare_account_token.deploy_token"
					attribute:    "value"
				}
			}
		}
	}
}
