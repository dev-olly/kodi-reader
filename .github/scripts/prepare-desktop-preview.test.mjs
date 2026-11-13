import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,readdirSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const script=fileURLToPath(new URL('./prepare-desktop-preview.mjs',import.meta.url));
const sha='a'.repeat(40);
function fixture(){
 const root=mkdtempSync(join(tmpdir(),'kodi-preview-upload-')),input=join(root,'input'),output=join(root,'output');
 for(const [target,files] of [['x86_64-pc-windows-msvc',{'Original setup.exe':Buffer.from('4d5a000102','hex')}],['x86_64-unknown-linux-gnu',{'Original.AppImage':Buffer.from('7f454c460001','hex'),'Original.deb':Buffer.from('!<arch>\nfixture'),'Original.rpm':Buffer.from('edabeedb0001','hex')}]]){
  const directory=join(input,target);mkdirSync(directory,{recursive:true});
  const manifest={version:'0.1.0',target,sourceCommit:sha,publicReleaseReady:false,updaterEnabled:false,installers:Object.keys(files),nativeSmokeEvidence:target.includes('linux')};
  files['preview-manifest.json']=JSON.stringify(manifest);files['THIRD_PARTY_NOTICES.md']='Codec source notices fixture';
  for(const [name,data] of Object.entries(files))writeFileSync(join(directory,name),data);
  writeFileSync(join(directory,'SHA256SUMS'),Object.keys(files).map(name=>`${createHash('sha256').update(readFileSync(join(directory,name))).digest('hex')}  ${name}`).join('\n')+'\n');
 }
 return{root,input,output,run:()=>spawnSync(process.execPath,[script,input,output,sha,'123'],{encoding:'utf8'}),close:()=>rmSync(root,{recursive:true,force:true})};
}
test('preview upload preparation verifies both builds and produces portable release names, notices and checksums',()=>{
 const f=fixture();try{const result=f.run();assert.equal(result.status,0,result.stderr);const m=JSON.parse(readFileSync(join(f.output,'release-manifest.json')));assert.equal(m.sourceCommit,sha);assert.equal(m.signed,false);assert.equal(m.manualAcceptance,false);assert.equal(m.platforms.length,2);assert.equal(m.platforms.flatMap(p=>p.packages).length,4);for(const p of m.platforms){assert.ok(!p.support.name.includes(' '));assert.ok(readFileSync(join(f.output,p.support.name)).subarray(0,2).equals(Buffer.from('PK')));for(const item of p.packages)assert.equal(createHash('sha256').update(readFileSync(join(f.output,item.name))).digest('hex'),item.sha256);}assert.equal(readdirSync(f.output).length,8);}finally{f.close();}
});
test('preview upload preparation rejects altered installer bytes before creating a release',()=>{
 const f=fixture();try{writeFileSync(join(f.input,'x86_64-pc-windows-msvc','Original setup.exe'),'tampered');const result=f.run();assert.notEqual(result.status,0);assert.match(result.stderr,/integrity failure/);}finally{f.close();}
});
