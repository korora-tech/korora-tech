package cuenv

import (
	"github.com/cuenv/cuenv/schema"
	xContributors "github.com/cuenv/cuenv/contrib/contributors"
	"registry.terraform.io/cloudflare/cloudflare:cloudflare_provider"
	"registry.terraform.io/cloudflare/cloudflare/resources/cloudflare_account_token"
	"registry.terraform.io/infisical/infisical:infisical_provider"
	"registry.terraform.io/infisical/infisical/resources/infisical_identity"
	"registry.terraform.io/infisical/infisical/resources/infisical_identity_oidc_auth"
	"registry.terraform.io/infisical/infisical/resources/infisical_project_identity"
	"registry.terraform.io/infisical/infisical/resources/infisical_secret"
)

schema.#Project

name: "korora-tech"

let _accountId = "0aeb879de8e3cdde5fb3d413025222ce"

let _zoneId = "8616ab6882fb4d01da13eb379f406f9a" // korora.tech

let _infisicalOrgId = "ceffb723-21f4-4452-beea-56d25ed1f9d9"

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

	// Deploys use the scoped korora-tech token from Infisical, never the root
	// token, and only the deploy task can read it.
	environment: production: {
		CLOUDFLARE_API_TOKEN: {
			value: schema.#InfisicalSecret & {
				projectId:   _infisicalProjectId
				environment: "production"
				secretName:  "CLOUDFLARE_API_TOKEN"
			}
			policies: [{allowTasks: ["deploy"]}]
		}
	}
}

let _t = tasks

let _sources = [
	"astro.config.mjs",
	"bun.lock",
	"package.json",
	"public/**",
	"src/**",
	"tsconfig.json",
]

tasks: {
	build: schema.#Task & {
		hermetic: false
		command:  "bun"
		args: ["run", "build"]
		inputs: _sources
		outputs: ["dist/**"]
	}

	deploy: schema.#Task & {
		hermetic: false
		command:  "bunx"
		args: ["wrangler@4.155.0", "deploy"]
		inputs: ["wrangler.jsonc"]
		dependsOn: [build]
	}
}

// GitHub-hosted runners don't ship Bun.
let _setupBun = schema.#Contributor & {
	id: "setupBun"
	when: always: true
	tasks: [{
		id:       "setupBun.install"
		label:    "Setup Bun"
		priority: 5
		provider: github: uses: "oven-sh/setup-bun@v2"
	}]
}

config: ci: cuenv: {
	source:  "release"
	version: "0.61.0"
}

ci: providers: ["github"]

// Deploys log in to Infisical with GitHub OIDC, so the repository stores no
// Infisical credential. The identity is infisical_identity.github_actions;
// see the OIDC resources below for what it may read.
ci: contributors: [
	_setupBun,
	xContributors.#CuenvRelease,
	xContributors.#BunWorkspace,
	xContributors.#Infisical,
	xContributors.#InfisicalOidc,
]

ci: pipelines: default: {
	environment: "production"
	when: {
		branch: ["main"]
		defaultBranch: true
		manual:        true
	}
	tasks: [_t.deploy]
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

		// GitHub Actions in the production environment of this repository log
		// in to Infisical with OIDC and can only read this project's secrets.
		github_actions: infisical_identity.#Resource & {
			configuration: {
				name:   "korora-tech-github-actions"
				org_id: _infisicalOrgId
				role:   "no-access"
			}
		}

		github_actions_oidc: infisical_identity_oidc_auth.#Resource & {
			configuration: {
				identity_id: schema.#InfrastructureOutputReference & {
					fromResource: "infisical_identity.github_actions"
					attribute:    "id"
				}
				oidc_discovery_url: "https://token.actions.githubusercontent.com"
				bound_issuer:       "https://token.actions.githubusercontent.com"
				bound_subject:      "repo:korora-tech/korora-tech:environment:production"
				bound_audiences: ["https://github.com/korora-tech"]
				access_token_ttl:     600
				access_token_max_ttl: 600
			}
		}

		github_actions_project: infisical_project_identity.#Resource & {
			configuration: {
				identity_id: schema.#InfrastructureOutputReference & {
					fromResource: "infisical_identity.github_actions"
					attribute:    "id"
				}
				project_id: _infisicalProjectId
				roles: [{role_slug: "viewer"}]
			}
		}
	}
}
