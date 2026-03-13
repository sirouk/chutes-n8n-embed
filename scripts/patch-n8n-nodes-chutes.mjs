import fs from 'node:fs';
import path from 'node:path';

const buildDir = process.argv[2];

if (!buildDir) {
	console.error('Usage: node patch-n8n-nodes-chutes.mjs <build-dir>');
	process.exit(1);
}

function replaceOrThrow(source, needle, replacement, filePath) {
	if (!source.includes(needle)) {
		throw new Error(`Could not find patch marker in ${filePath}`);
	}

	return source.replace(needle, replacement);
}

function patchCredentialTestBaseUrl() {
	const credentialFile = path.join(buildDir, 'credentials', 'ChutesApi.credentials.ts');
	let source = fs.readFileSync(credentialFile, 'utf8');

	if (!source.includes('CHUTES_CREDENTIAL_TEST_BASE_URL')) {
		const marker = "const FORCE_REFRESH_FLAG = '__n8nForceCredentialRefresh';\n";
		source = replaceOrThrow(
			source,
			marker,
			`${marker}
function getCredentialTestBaseUrl(): string {
\treturn (
\t\tprocess.env.CHUTES_CREDENTIAL_TEST_BASE_URL?.trim() ||
\t\t'={{$credentials.customUrl || ($credentials.environment === "sandbox" ? "https://sandbox-llm.chutes.ai" : "https://llm.chutes.ai")}}'
\t);
}
`,
			credentialFile,
		);

		source = source.replace(
			/\ttest: ICredentialTestRequest = \{\n\t\trequest: \{\n\t\t\tbaseURL:\n\t\t\t\t'=\{\{\$credentials\.customUrl \|\| \(\$credentials\.environment === "sandbox" \? "https:\/\/sandbox-llm\.chutes\.ai" : "https:\/\/llm\.chutes\.ai"\)\}\}',/,
			`\ttest: ICredentialTestRequest = {\n\t\trequest: {\n\t\t\tbaseURL: getCredentialTestBaseUrl(),`,
		);
	}

	fs.writeFileSync(credentialFile, source);
}

function patchResourceChooser() {
	const nodeFile = path.join(buildDir, 'nodes', 'Chutes', 'Chutes.node.ts');
	let source = fs.readFileSync(nodeFile, 'utf8');

	if (!source.includes("name: 'Choose Resource Type'")) {
		source = replaceOrThrow(
			source,
			`options: [
\t\t\t\t\t{
\t\t\t\t\t\tname: 'LLM (Text Generation)',`,
			`options: [
\t\t\t\t\t{
\t\t\t\t\t\tname: 'Choose Resource Type',
\t\t\t\t\t\tvalue: '',
\t\t\t\t\t\tdescription: 'Select the kind of Chutes model you want to use',
\t\t\t\t\t},
\t\t\t\t\t{
\t\t\t\t\t\tname: 'LLM (Text Generation)',`,
			nodeFile,
		);
	}

	source = replaceOrThrow(
		source,
		`default: 'textGeneration',`,
		`default: '',`,
		nodeFile,
	);

	source = replaceOrThrow(
		source,
		`default: 'https://llm.chutes.ai',`,
		`default: '',`,
		nodeFile,
	);

	source = replaceOrThrow(
		source,
		`placeholder: 'https://llm.chutes.ai',`,
		`placeholder: 'Select a resource type first',`,
		nodeFile,
	);

	if (source.includes(`subtitle: '={{$parameter["operation"] + ": " + $parameter["resource"]}}',`)) {
		source = source.replace(
			`subtitle: '={{$parameter["operation"] + ": " + $parameter["resource"]}}',`,
			`subtitle: '={{$parameter["resource"] ? $parameter["operation"] + ": " + $parameter["resource"] : "choose resource"}}',`,
		);
	}

	fs.writeFileSync(nodeFile, source);
}

function patchResourceAwareChuteLoading() {
	const loadChutesFile = path.join(buildDir, 'nodes', 'Chutes', 'methods', 'loadChutes.ts');
	let source = fs.readFileSync(loadChutesFile, 'utf8');

	if (!source.includes('const SELECT_RESOURCE_TYPE_OPTION')) {
		source = replaceOrThrow(
			source,
			`let hasLoggedPublicCatalogFallback = false;
`,
			`let hasLoggedPublicCatalogFallback = false;

const SELECT_RESOURCE_TYPE_OPTION: INodePropertyOptions = {
\tname: 'Select a resource type first',
\tvalue: '',
\tdescription: 'Choose a resource type to load matching chutes.',
};
`,
			loadChutesFile,
		);
	}

	if (
		source.includes(`return (context.getCurrentNodeParameter('resource') as string) || 'textGeneration';`) &&
		source.includes(`return 'textGeneration';`)
	) {
		source = source.replace(
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn (context.getCurrentNodeParameter('resource') as string) || 'textGeneration';
\t} catch {
\t\treturn 'textGeneration';
\t}
}`,
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn String(context.getCurrentNodeParameter('resource') ?? '').trim();
\t} catch {
\t\treturn '';
\t}
}`,
		);
	}

	if (!source.includes('if (!resource) {\n\t\treturn [SELECT_RESOURCE_TYPE_OPTION];\n\t}')) {
		source = replaceOrThrow(
			source,
			`): Promise<INodePropertyOptions[]> {
\tconst resource = getCurrentResource(this);

\tswitch (resource) {`,
			`): Promise<INodePropertyOptions[]> {
\tconst resource = getCurrentResource(this);

\tif (!resource) {
\t\treturn [SELECT_RESOURCE_TYPE_OPTION];
\t}

\tswitch (resource) {`,
			loadChutesFile,
		);
	}

	if (source.includes(`\t\tdefault:\n\t\t\treturn await getChutes.call(this);`)) {
		source = source.replace(
			`\t\tdefault:\n\t\t\treturn await getChutes.call(this);`,
			`\t\tdefault:\n\t\t\treturn [SELECT_RESOURCE_TYPE_OPTION];`,
		);
	}

	fs.writeFileSync(loadChutesFile, source);
}

patchCredentialTestBaseUrl();
patchResourceChooser();
patchResourceAwareChuteLoading();
