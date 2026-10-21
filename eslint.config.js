import js from '@eslint/js';
import globals from 'globals';

export default [
    { ignores: ['**/node_modules/**', 'reports/**', 'artifacts/**', '.local/**'] },
    js.configs.recommended,
    {
        files: ['**/*.{js,mjs,cjs}'],
        languageOptions: { ecmaVersion: 'latest', sourceType: 'module', globals: { ...globals.node } },
        rules: {
            'no-unused-vars': [
                'error',
                { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrorsIgnorePattern: '^_' },
            ],
            // Storage and best-effort calls swallow errors on purpose.
            'no-empty': ['error', { allowEmptyCatch: true }],
        },
    },
    { files: ['**/*.cjs'], languageOptions: { sourceType: 'commonjs' } },
    {
        // Classic browser scripts loaded with <script src>.
        files: ['site/app.js', 'site/theme.js', 'site/collectors.js'],
        languageOptions: { sourceType: 'script', globals: { ...globals.browser } },
        rules: { 'no-console': ['warn', { allow: ['warn', 'error'] }] },
    },
    {
        // page.evaluate callbacks run in the browser.
        files: ['scripts/Test-WebStandard.mjs'],
        languageOptions: { globals: { ...globals.node, ...globals.browser } },
    },
];
