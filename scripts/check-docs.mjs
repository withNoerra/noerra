import {readdir,readFile,stat} from 'node:fs/promises';
import {resolve,dirname,relative} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
let checked=0;const errors=[];
async function walk(dir){for(const entry of await readdir(dir,{withFileTypes:true})){if(['node_modules','lib','out','cache','dist','output','.git'].includes(entry.name))continue;const path=resolve(dir,entry.name);if(entry.isDirectory())await walk(path);else if(entry.name.endsWith('.md')){const text=await readFile(path,'utf8');for(const match of text.matchAll(/!?\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)/g)){const target=match[1];if(/^(?:https?:|mailto:|#)/.test(target))continue;const file=decodeURIComponent(target.split('#')[0]);if(!file)continue;const full=resolve(dirname(path),file);if(relative(root,full).startsWith('..')){errors.push(`${relative(root,path)}: link leaves repository ${target}`);continue;}try{await stat(full);checked++;}catch{errors.push(`${relative(root,path)}: missing ${target}`);}}}}}
await walk(root);if(errors.length)throw Error(errors.join('\n'));console.log(`Documentation links passed (${checked} local targets).`);
