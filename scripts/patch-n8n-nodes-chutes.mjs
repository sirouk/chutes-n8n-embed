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

function replaceRegexOrThrow(source, pattern, replacement, filePath) {
	if (!pattern.test(source)) {
		throw new Error(`Could not find patch marker in ${filePath}`);
	}

	return source.replace(pattern, replacement);
}

const RESOURCE_PLACEHOLDER_VALUE = '__choose_resource_type__';

function patchCredentialTestBaseUrl() {
	const credentialFile = path.join(buildDir, 'credentials', 'ChutesApi.credentials.ts');
	let source = fs.readFileSync(credentialFile, 'utf8');

	if (!source.includes('CHUTES_CREDENTIAL_TEST_BASE_URL')) {
		const helperFunction = `function getCredentialTestBaseUrl(): string {
\treturn (
\t\tprocess.env.CHUTES_CREDENTIAL_TEST_BASE_URL?.trim() ||
\t\t'={{$credentials.customUrl || ($credentials.environment === "sandbox" ? "https://sandbox-llm.chutes.ai" : "https://llm.chutes.ai")}}'
\t);
}
`;
		const marker = "const FORCE_REFRESH_FLAG = '__n8nForceCredentialRefresh';\n";

		if (source.includes(marker)) {
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
		} else {
			const exportMarker = '\nexport class ChutesApi implements ICredentialType {\n';
			source = replaceOrThrow(
				source,
				exportMarker,
				`\n${helperFunction}\nexport class ChutesApi implements ICredentialType {\n`,
				credentialFile,
			);
		}

		source = replaceRegexOrThrow(
			source,
			/baseURL:\s*(?:getCredentialTestBaseUrl\(\)|'=\{\{\$credentials\.customUrl \|\| \(\$credentials\.environment === "sandbox" \? "https:\/\/sandbox-llm\.chutes\.ai" : "https:\/\/llm\.chutes\.ai"\)\}\}')\s*,/,
			`baseURL: getCredentialTestBaseUrl(),`,
			credentialFile,
		);
	}

	fs.writeFileSync(credentialFile, source);
}

function patchResourceChooser() {
	const nodeFile = path.join(buildDir, 'nodes', 'Chutes', 'Chutes.node.ts');
	let source = fs.readFileSync(nodeFile, 'utf8');

	if (source.includes(`value: '${RESOURCE_PLACEHOLDER_VALUE}'`)) {
		// Already patched.
	} else if (source.includes("name: 'Choose Resource Type'")) {
		source = source.replace(
			`name: 'Choose Resource Type',
\t\t\t\t\t\tvalue: '',`,
			`name: 'Choose Resource Type',
\t\t\t\t\t\tvalue: '${RESOURCE_PLACEHOLDER_VALUE}',`,
		);
	} else {
		source = replaceOrThrow(
			source,
			`options: [
\t\t\t\t\t{
\t\t\t\t\t\tname: 'LLM (Text Generation)',`,
			`options: [
\t\t\t\t\t{
\t\t\t\t\t\tname: 'Choose Resource Type',
\t\t\t\t\t\tvalue: '${RESOURCE_PLACEHOLDER_VALUE}',
\t\t\t\t\t\tdescription: 'Select the kind of Chutes model you want to use',
\t\t\t\t\t},
\t\t\t\t\t{
\t\t\t\t\t\tname: 'LLM (Text Generation)',`,
			nodeFile,
		);
	}

	if (source.includes(`default: 'textGeneration',`)) {
		source = source.replace(
			`default: 'textGeneration',`,
			`default: '${RESOURCE_PLACEHOLDER_VALUE}',`,
		);
	} else if (source.includes(`default: '',`)) {
		source = source.replace(
			`default: '',`,
			`default: '${RESOURCE_PLACEHOLDER_VALUE}',`,
		);
	}

	if (source.includes(`default: 'https://llm.chutes.ai',`)) {
		source = source.replace(
			`default: 'https://llm.chutes.ai',`,
			`default: '',`,
		);
	}

	if (source.includes(`placeholder: 'https://llm.chutes.ai',`)) {
		source = source.replace(
			`placeholder: 'https://llm.chutes.ai',`,
			`placeholder: 'Select a resource type first',`,
		);
	}

	const subtitleNeedleLegacy = `subtitle: '={{$parameter["operation"] + ": " + $parameter["resource"]}}',`;
	const subtitleNeedleCurrent = `subtitle: '={{$parameter["resource"] ? $parameter["operation"] + ": " + $parameter["resource"] : "choose resource"}}',`;
	const subtitleReplacement = `subtitle: '={{$parameter["resource"] && $parameter["resource"] !== "${RESOURCE_PLACEHOLDER_VALUE}" ? ($parameter["operation"] ? $parameter["operation"] + ": " : "") + $parameter["resource"] : "choose resource"}}',`;
	if (source.includes(subtitleNeedleLegacy)) {
		source = source.replace(subtitleNeedleLegacy, subtitleReplacement);
	}
	if (source.includes(subtitleNeedleCurrent)) {
		source = source.replace(subtitleNeedleCurrent, subtitleReplacement);
	}

	fs.writeFileSync(nodeFile, source);
}

function patchResourceAwareChuteLoading() {
	const loadChutesFile = path.join(buildDir, 'nodes', 'Chutes', 'methods', 'loadChutes.ts');
	let source = fs.readFileSync(loadChutesFile, 'utf8');

	if (!source.includes('requestWithChutesCredential')) {
		// Older upstream node revisions still use resource-specific chute fields, so the
		// resource-aware shared-dropdown patch is not needed for that shape.
		return;
	}

	if (source.includes(`value: '${RESOURCE_PLACEHOLDER_VALUE}'`)) {
		// Already patched.
	} else if (source.includes('const SELECT_RESOURCE_TYPE_OPTION')) {
		source = source.replace(
			`const SELECT_RESOURCE_TYPE_OPTION: INodePropertyOptions = {
\tname: 'Select a resource type first',
\tvalue: '',
\tdescription: 'Choose a resource type to load matching chutes.',
};`,
			`const SELECT_RESOURCE_TYPE_OPTION: INodePropertyOptions = {
\tname: 'Select a resource type first',
\tvalue: '${RESOURCE_PLACEHOLDER_VALUE}',
\tdescription: 'Choose a resource type to load matching chutes.',
};`,
		);
	} else {
		source = replaceOrThrow(
			source,
			`let hasLoggedPublicCatalogFallback = false;
`,
			`let hasLoggedPublicCatalogFallback = false;

const SELECT_RESOURCE_TYPE_OPTION: INodePropertyOptions = {
\tname: 'Select a resource type first',
\tvalue: '${RESOURCE_PLACEHOLDER_VALUE}',
\tdescription: 'Choose a resource type to load matching chutes.',
};
`,
			loadChutesFile,
		);
	}

	if (source.includes(`return (context.getCurrentNodeParameter('resource') as string) || 'textGeneration';`)) {
		source = source.replace(
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn (context.getCurrentNodeParameter('resource') as string) || 'textGeneration';
\t} catch {
\t\treturn '';
\t}
}`,
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn String(context.getCurrentNodeParameter('resource') ?? '').trim();
\t} catch {
\t\treturn '${RESOURCE_PLACEHOLDER_VALUE}';
\t}
}`,
		);
	} else if (source.includes(`return String(context.getCurrentNodeParameter('resource') ?? '').trim();`)) {
		source = source.replace(
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn String(context.getCurrentNodeParameter('resource') ?? '').trim();
\t} catch {
\t\treturn '';
\t}
}`,
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn String(context.getCurrentNodeParameter('resource') ?? '').trim();
\t} catch {
\t\treturn '${RESOURCE_PLACEHOLDER_VALUE}';
\t}
}`,
		);
	}

	if (source.includes(`if (!resource) {\n\t\treturn [SELECT_RESOURCE_TYPE_OPTION];\n\t}`)) {
		source = source.replace(
			`if (!resource) {
\t\treturn [SELECT_RESOURCE_TYPE_OPTION];
\t}`,
			`if (!resource || resource === '${RESOURCE_PLACEHOLDER_VALUE}') {
\t\treturn [SELECT_RESOURCE_TYPE_OPTION];
\t}`,
		);
	} else if (!source.includes(`if (!resource || resource === '${RESOURCE_PLACEHOLDER_VALUE}') {\n\t\treturn [SELECT_RESOURCE_TYPE_OPTION];\n\t}`)) {
		source = replaceOrThrow(
			source,
			`): Promise<INodePropertyOptions[]> {
\tconst resource = getCurrentResource(this);

\tswitch (resource) {`,
			`): Promise<INodePropertyOptions[]> {
\tconst resource = getCurrentResource(this);

\tif (!resource || resource === '${RESOURCE_PLACEHOLDER_VALUE}') {
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

function patchNeutralNodeCreatorFlow() {
	const operationsDir = path.join(buildDir, 'nodes', 'Chutes', 'operations');

	for (const entry of fs.readdirSync(operationsDir)) {
		if (!entry.endsWith('.ts')) {
			continue;
		}

		const operationFile = path.join(operationsDir, entry);
		const source = fs.readFileSync(operationFile, 'utf8');
		const patched = source.replace(/^\s*action: '.*?',\n/gm, '');

		if (patched !== source) {
			fs.writeFileSync(operationFile, patched);
		}
	}
}

patchCredentialTestBaseUrl();
patchResourceChooser();
patchResourceAwareChuteLoading();
patchNeutralNodeCreatorFlow();
