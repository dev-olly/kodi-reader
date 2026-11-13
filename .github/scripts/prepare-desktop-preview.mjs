import {readFileSync,readdirSync,copyFileSync,mkdirSync,statSync,writeFileSync,existsSync} from 'node:fs';
import {resolve,join,basename} from 'node:path';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
const [input,output,commit,run]=process.argv.slice(2);
if(!input||!output||!/^[a-f0-9]{40}$/.test(commit||'')||!/^\d+$/.test(run||''))throw Error('Supply artifact directory, empty upload directory, source SHA, run ID');
const root=resolve(input), destination=resolve(output);
if(existsSync(destination)&&readdirSync(destination).length)throw Error('Upload directory must be empty');
mkdirSync(destination,{recursive:true});
const hash=file=>createHash('sha256').update(readFileSync(file)).digest('hex');
const platforms=[]; let version;
for(const directory of readdirSync(root,{withFileTypes:true}).filter(entry=>entry.isDirectory())){
 const path=join(root,directory.name), manifest=JSON.parse(readFileSync(join(path,'preview-manifest.json'),'utf8'));
 if(manifest.sourceCommit!==commit||manifest.publicReleaseReady!==false||manifest.updaterEnabled!==false)throw Error('Invalid artifact provenance');
 if(!/^\d+\.\d+\.\d+$/.test(manifest.version||'')||(version&&version!==manifest.version))throw Error('Invalid or mixed package versions');
 version=manifest.version;
 const verified=new Set();
 for(const line of readFileSync(join(path,'SHA256SUMS'),'utf8').trim().split('\n')){const match=line.match(/^([a-f0-9]{64})  (.+)$/);if(!match||verified.has(match[2]))throw Error('Invalid checksum');const file=resolve(path,match[2]);if(!file.startsWith(path+'/')||hash(file)!==match[1])throw Error('Artifact integrity failure: '+match[2]);verified.add(match[2]);}
 const windows=manifest.target==='x86_64-pc-windows-msvc';
 if(!windows&&manifest.target!=='x86_64-unknown-linux-gnu')throw Error('Unexpected platform');
 if(!Array.isArray(manifest.installers)||manifest.installers.length!==(windows?1:3)||manifest.installers.some(name=>basename(name)!==name||!verified.has(name)))throw Error('Invalid installer inventory');
 const packages=manifest.installers.map(originalName=>{const format=originalName.endsWith('.exe')?'exe':originalName.endsWith('.AppImage')?'AppImage':originalName.endsWith('.deb')?'deb':originalName.endsWith('.rpm')?'rpm':null;if(!format)throw Error('Unknown installer format');const name=format==='exe'?`KodiReader-Preview-${version}-windows-x64-setup.exe`:`KodiReader-Preview-${version}-linux-${format==='deb'?'amd64':'x86_64'}.${format}`;const file=join(path,originalName);const bytes=readFileSync(file);const magic={exe:'4d5a',AppImage:'7f454c46',deb:'213c617263683e0a',rpm:'edabeedb'}[format];if(bytes.subarray(0,magic.length/2).toString('hex')!==magic)throw Error('Invalid installer bytes');copyFileSync(file,join(destination,name));return{name,originalName,format,bytes:statSync(file).size,sha256:hash(file)};});
 if(windows?packages[0].format!=='exe':new Set(packages.map(p=>p.format)).size!==3||packages.some(p=>p.format==='exe'))throw Error('Wrong platform package formats');
 const support=`KodiReader-Preview-${version}-${windows?'windows-x64':'linux-x86_64'}-codec-source-and-notices.zip`;
 const zipScript='import os,sys,json,zipfile\nroot,out,exclude=sys.argv[1],sys.argv[2],set(json.loads(sys.argv[3]))\nwith zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED) as z:\n for base,dirs,files in os.walk(root):\n  for name in files:\n   p=os.path.join(base,name); rel=os.path.relpath(p,root)\n   if rel not in exclude:z.write(p,rel)\n';
 const zipped=spawnSync('python3',['-c',zipScript,path,join(destination,support),JSON.stringify(manifest.installers)],{encoding:'utf8'});if(zipped.status!==0)throw Error('Could not archive codec sources/notices');
 platforms.push({target:manifest.target,packages,support:{name:support,sha256:hash(join(destination,support))},nativeSmokeEvidence:manifest.nativeSmokeEvidence});
}
if(platforms.length!==2||new Set(platforms.map(p=>p.target)).size!==2)throw Error('Both platforms required');
writeFileSync(join(destination,'release-manifest.json'),JSON.stringify({version,channel:'preview',sourceCommit:commit,workflowRunURL:`https://github.com/dev-olly/kodi-reader/actions/runs/${run}`,signed:false,manualAcceptance:false,updaterEnabled:false,platforms},null,2)+'\n');
const files=readdirSync(destination).sort();writeFileSync(join(destination,'SHA256SUMS'),files.map(name=>`${hash(join(destination,name))}  ${basename(name)}`).join('\n')+'\n');
console.log(JSON.stringify({verified:true,sourceCommit:commit,platforms:platforms.map(p=>({target:p.target,packages:p.packages.map(x=>x.name),nativeSmokeEvidence:p.nativeSmokeEvidence})),releaseFiles:readdirSync(destination).length},null,2));
