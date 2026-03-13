import fs from 'node:fs';
import path from 'node:path';

const buildDir = process.argv[2];

if (!buildDir) {
	console.error('Usage: node patch-n8n-nodes-chutes.mjs <build-dir>');
	process.exit(1);
}

const credentialFile = path.join(buildDir, 'credentials', 'ChutesApi.credentials.ts');
let source = fs.readFileSync(credentialFile, 'utf8');

if (source.includes('CHUTES_CREDENTIAL_TEST_BASE_URL')) {
	process.exit(0);
}

const marker = "const FORCE_REFRESH_FLAG = '__n8nForceCredentialRefresh';\n";
if (!source.includes(marker)) {
	throw new Error(`Could not find patch marker in ${credentialFile}`);
}

source = source.replace(
	marker,
	`${marker}
function getCredentialTestBaseUrl(): string {
\treturn (
\t\tprocess.env.CHUTES_CREDENTIAL_TEST_BASE_URL?.trim() ||
\t\t'={{$credentials.customUrl || ($credentials.environment === "sandbox" ? "https://sandbox-llm.chutes.ai" : "https://llm.chutes.ai")}}'
\t);
}
`,
);

source = source.replace(
	/\ttest: ICredentialTestRequest = \{\n\t\trequest: \{\n\t\t\tbaseURL:\n\t\t\t\t'=\{\{\$credentials\.customUrl \|\| \(\$credentials\.environment === "sandbox" \? "https:\/\/sandbox-llm\.chutes\.ai" : "https:\/\/llm\.chutes\.ai"\)\}\}',/,
	`\ttest: ICredentialTestRequest = {\n\t\trequest: {\n\t\t\tbaseURL: getCredentialTestBaseUrl(),`,
);

fs.writeFileSync(credentialFile, source);
