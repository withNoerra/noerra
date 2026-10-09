import {build} from 'esbuild';
import {mkdir,mkdtemp,readFile,writeFile,copyFile,lstat} from 'node:fs/promises';
import {createHash} from 'node:crypto';import {resolve,join,sep} from 'node:path';import {fileURLToPath,pathToFileURL} from 'node:url';
export const SDK_MODULES=Object.freeze(['agents','agent-memory','agent-chain','agent-ecosystem','agent-compute','agent-diem','access-market']);
export const SDK_INTERNAL=Object.freeze(['stewardship','automatic-activation-intent']);
const repo=fileURLToPath(new URL('../',import.meta.url));
const exists=async path=>{try{return (await lstat(path)).isFile();}catch(e){if(e.code==='ENOENT')return false;throw e;}};
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
export function sdkPackage(version='0.1.0'){return {name:'@noerra/sdk',version,private:true,type:'module',description:'Noerra agent clients, pinned markets, memory exports and compute',engines:{node:'>=24 <25'},types:'./dist/index.d.ts',exports:Object.fromEntries(['index',...SDK_MODULES].map(name=>[name==='index'?'.':'./'+name,{types:'./dist/'+name+'.d.ts',import:'./dist/'+name+'.js'}]).concat([['./abi/*','./abi/*']])),files:['dist','abi','README.md','sdk-manifest.json'],dependencies:{viem:'2.57.2'}};}
/** Exact public allowlist. Legacy chat/wallet SDKs and backend files never enter
 * the staging tree or dependency graph. Only these pure browser helpers move
 * into sdk/internal in the proposed public repository. */
export async function stagePublicSdk({sourceRoot=repo,destination=join(sourceRoot,'output/public-repository-proposal/sdk')}={}){
 if(resolve(sourceRoot)!==resolve(repo)||!resolve(destination).startsWith(resolve(repo,'output')+sep))throw Error('SDK source is read-only; staging must remain inside this repository output directory.');
 await mkdir(join(destination,'internal'),{recursive:true});await mkdir(join(destination,'abi'),{recursive:true});const sourceHashes={},requiredAbis=new Set();
 for(const name of SDK_MODULES){const path=join(sourceRoot,'sdk',name+'.mjs'),original=await readFile(path,'utf8');sourceHashes['sdk/'+name+'.mjs']=hash(original);const text=original;
  if(/(?:\.\.\/runtime|\.\.\/vendor|node:|zkapi|confidential-chat|private-wallet-backup)/.test(text))throw Error('Unexpected dependency in current public SDK: '+name);
  for(const match of text.matchAll(/['"]\.\/abi\/([A-Za-z0-9]+\.json)['"]/g))requiredAbis.add(match[1]);await writeFile(join(destination,name+'.mjs'),text);
  if(name!=='access-market'){const from=join(sourceRoot,'sdk',name+'.d.ts'),bytes=await readFile(from);sourceHashes['sdk/'+name+'.d.ts']=hash(bytes);await writeFile(join(destination,name+'.d.ts'),bytes);}
 }
 for(const name of SDK_INTERNAL){const local=join(sourceRoot,'sdk/internal',name+'.mjs'),bytes=await readFile(local,'utf8');if(/node:|^import.*\.\.\//m.test(bytes))throw Error('Public internal helper gained a backend dependency.');sourceHashes['sdk/internal/'+name+'.mjs']=hash(bytes);await writeFile(join(destination,'internal',name+'.mjs'),bytes);}
 const declaration=await readFile(join(sourceRoot,'sdk/access-market.d.ts'),'utf8');await writeFile(join(destination,'access-market.d.ts'),declaration.trimEnd()+'\n');
 await writeFile(join(destination,'index.mjs'),SDK_MODULES.map(name=>`export * from './${name}.mjs';`).join('\n')+'\n');await writeFile(join(destination,'index.d.ts'),SDK_MODULES.map(name=>`export * from './${name}.js';`).join('\n')+'\n');
 for(const name of [...requiredAbis].sort()){const bytes=await readFile(join(sourceRoot,'sdk/abi',name));if(!Array.isArray(JSON.parse(bytes)))throw Error('Only public ABI arrays are accepted.');sourceHashes['sdk/abi/'+name]=hash(bytes);await writeFile(join(destination,'abi',name),bytes);}
 if(!await exists(join(destination,'README.md'))){const curated=await exists(join(sourceRoot,'sdk/index.mjs'))&&await exists(join(sourceRoot,'sdk/README.md'));await writeFile(join(destination,'README.md'),curated?await readFile(join(sourceRoot,'sdk/README.md'),'utf8'):'# @noerra/sdk\n\nCurrent agent, memory, pinned market and compute clients. Build with `npm run build:sdk`, prepare a local tarball with `npm run package:sdk`, then install the printed `.tgz` path. No npm publication occurs.\n\nImport from `@noerra/sdk` or the matching current-client subpaths. Deployment-specific contracts must be configured and verified before financial calls. No server code, private-chat clients, credentials or operator scripts are included.\n');}
 await writeFile(join(destination,'package.json'),JSON.stringify(sdkPackage(),null,2)+'\n');return {destination,sourceHashes,abis:[...requiredAbis].sort()};
}
export async function buildSdk({sourceRoot=repo,sourceDirectory,directory}={}){
 if(resolve(sourceRoot)!==resolve(repo)||directory&&!resolve(directory).startsWith(resolve(repo,'output')+sep))throw Error('Build only into this public repository output directory.');
 const staged=await stagePublicSdk({sourceRoot,destination:sourceDirectory||join(sourceRoot,'output/public-repository-proposal/sdk')});await mkdir(join(sourceRoot,'output'),{recursive:true});directory=directory||await mkdtemp(join(sourceRoot,'output/sdk-release-'));await mkdir(join(directory,'dist'),{recursive:true});await mkdir(join(directory,'abi'),{recursive:true});
 const entryPoints=Object.fromEntries(['index',...SDK_MODULES].map(name=>[name,join(staged.destination,name+'.mjs')]));const result=await build({absWorkingDir:sourceRoot,entryPoints,bundle:true,format:'esm',platform:'browser',target:'es2022',outdir:join(directory,'dist'),external:['viem'],minify:false,legalComments:'linked',metafile:true});
 if(Object.keys(result.metafile.inputs).some(p=>/vendor[\\/]|runtime[\\/]|zkapi|private-wallet|confidential-chat|noerra-client/.test(p)))throw Error('Excluded code entered public SDK graph.');
 for(const name of ['index',...SDK_MODULES])await copyFile(join(staged.destination,name+'.d.ts'),join(directory,'dist',name+'.d.ts'));
 for(const name of staged.abis)await copyFile(join(staged.destination,'abi',name),join(directory,'abi',name));await copyFile(join(staged.destination,'README.md'),join(directory,'README.md'));await writeFile(join(directory,'package.json'),JSON.stringify(sdkPackage(),null,2)+'\n');
 await writeFile(join(directory,'sdk-manifest.json'),JSON.stringify({version:2,published:false,publicClients:SDK_MODULES,sourceHashes:staged.sourceHashes,abis:staged.abis,inputs:Object.keys(result.metafile.inputs).map(p=>p.replaceAll('\\','/')),dependencies:sdkPackage().dependencies},null,2)+'\n');
 const prepared={directory,sourceDirectory:staged.destination,published:false,clients:SDK_MODULES,abis:staged.abis};await writeFile(join(sourceRoot,'output/sdk-build-latest.json'),JSON.stringify(prepared,null,2)+'\n');return prepared;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){console.log(JSON.stringify(await buildSdk()));}
