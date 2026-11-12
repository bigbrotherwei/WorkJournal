import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
process.chdir(fileURLToPath(new URL('.', import.meta.url)));
import { mkdir, copyFile, readFile, writeFile, readdir } from 'node:fs/promises';
const output='../Sources/WorkJournal/Resources/NotebookEditor';
await mkdir(output,{recursive:true});
const result=await build({absWorkingDir:process.cwd(),entryPoints:['src/app.js'],bundle:true,minify:true,format:'iife',target:['safari17'],outfile:`${output}/editor.js`,legalComments:'external',metafile:true});
await Promise.all(['index.html','editor.css'].map(name=>copyFile(`src/${name}`,`${output}/${name}`)));
const packages=new Set(Object.keys(result.metafile.inputs).flatMap(path=>{const match=/^node_modules\/((?:@[^/]+\/)?[^/]+)/.exec(path);return match?[match[1]]:[];}));
const licenses=[];
for(const name of [...packages].sort()) {
  const base=`node_modules/${name}`;
  const manifest=JSON.parse(await readFile(`${base}/package.json`,'utf8'));
  const files=(await readdir(base)).filter(file=>/^licen[cs]e(?:\.|$)/i.test(file));
  if(!files.length)throw new Error(`Missing license text for ${name}`);
  licenses.push(`===== ${name} ${manifest.version} (${manifest.license}) =====\n\n`+await readFile(`${base}/${files[0]}`,'utf8'));
}
await writeFile(`${output}/THIRD_PARTY_LICENSES.txt`,licenses.join('\n\n'));
console.log(`Bundled ${packages.size} packages; license texts included.`);
