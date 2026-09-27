import { readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
const web = new URL('../', import.meta.url);
const lock = JSON.parse(await readFile(new URL('package-lock.json', web)));
const sections = ['Third-party runtime dependency license notices\nGenerated from the exact packages in web/package-lock.json.'];
for (const [path, pkg] of Object.entries(lock.packages)) {
  if (!path || pkg.dev) continue;
  const directory = new URL(`${path}/`, web);
  const notices = (await readdir(directory)).filter(name => /^(licen[sc]e|copying)(\.|$)/i.test(name));
  for (const name of notices) sections.push(`${path} @ ${pkg.version}\n${await readFile(new URL(name, directory), 'utf8')}`);
}
await mkdir(new URL('public/', web), { recursive: true });
await writeFile(new URL('public/third-party-licenses.txt', web), sections.join('\n\n----------------------------------------\n\n') + '\n');
