import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {DAY,VERSION,SLOTS,freshLearning,summary,eligibility,expose,present,submit,selectQuestion,reviewDue,validateLearning} from '../lib/learning.ts';
const root=fileURLToPath(new URL('../',import.meta.url));
const course=JSON.parse(fs.readFileSync(root+'content/physics.json','utf8'));
const questions=[...course.delayedReview.checks,...course.lessons.flatMap(l=>l.checks)];
const byID=id=>{const q=questions.find(q=>q.id===id);assert.ok(q);return q;};
const T=1_800_000_000_000;
const at=d=>T+d*DAY;
let uid=0;const id=()=>`i${++uid}`;
const clone=x=>structuredClone(x);
function prepared(concepts=['force']){const l=freshLearning();expose(l,concepts,'lesson',T,id());return l;}
function show(l,d=1,q='force-later-1',review=true){return present(l,byID(q),review,at(d),id());}
function answer(l,p,d=1,correct=true,help=false){const q=byID(p.question);return submit(l,q,p.id,correct?q.correctChoiceId:q.choices.find(c=>c.id!==q.correctChoiceId).id,help,at(d));}
function validSuccess(){const l=prepared();const p=show(l);answer(l,p);assert.equal(validateLearning(l),true);return l;}
function rejected(value){try{return validateLearning(value)===false}catch{return true}}
const results=[];
function test(name,run){try{run();results.push({name,pass:true});}catch(e){results.push({name,pass:false,error:e.message});}}
test('Fresh account: unknown and no retroactive points',()=>{const l=freshLearning();l.completed=['physics-02'];l.learned.force=T;assert.equal(summary(l,T).points,0);assert.equal(summary(l,T).checked,0);assert.equal(eligibility(l,byID('force-later-1'),true,at(20)).canCount,false);});
test('24-hour boundary locked before display',()=>{const early=prepared(),p=show(early,1-1/86400);assert.equal(p.eligibility.canCount,false);assert.equal(answer(early,p,2).counted,false);const exact=prepared(),p2=show(exact);assert.equal(p2.eligibility.canCount,true);assert.equal(answer(exact,p2).delta,10);});
test('Question skip still restarts seven-day display clock',()=>{const l=prepared();show(l);assert.equal(eligibility(l,byID('force-later-1'),true,at(8)-1000).canCount,false);assert.equal(eligibility(l,byID('force-later-1'),true,at(8)).canCount,true);});
test('Exact slot correct repeat wrong recovery',()=>{const l=prepared();for(const [day,correct,delta] of [[1,true,10],[8,true,0],[15,false,-10],[22,true,10]]){const p=show(l,day);assert.equal(p.eligibility.canCount,true);assert.equal(answer(l,p,day,correct).delta,delta);}assert.equal(summary(l,at(22)).points,10);assert.equal(summary(l,at(22)).checked,1);assert.equal(validateLearning(l),true);});
test('First wrong counts evidence without negative points',()=>{const l=prepared(),r=answer(l,show(l),1,false);assert.equal(r.counted,true);assert.equal(r.delta,0);assert.equal(summary(l,at(1)).checked,1);assert.equal(summary(l,at(1)).points,0);});
test('Latest eligible receipt wins over later practice wrong',()=>{const l=validSuccess();const p=show(l,1.5);assert.equal(answer(l,p,1.5,false).counted,false);assert.equal(summary(l,at(2)).points,10);});
test('Eligible no-help wrong replaces earlier slot only',()=>{const l=prepared(['force','energy']);answer(l,show(l),1);answer(l,show(l,1,'energy-later-1'),1);answer(l,show(l,8),8,false);assert.equal(summary(l,at(8)).points,10);assert.equal(summary(l,at(8)).checked,2);});
test('Recorded help overrides false submitted help flag',()=>{const l=prepared(),p=show(l);expose(l,['force'],'help',at(1),id(),p.question,p.id);const r=answer(l,p);assert.equal(r.counted,false);assert.equal(r.helped,true);assert.equal(summary(l,at(1)).checked,0);});
test('Self-reported help is unscored',()=>{const l=prepared(),p=show(l);const r=answer(l,p,1,true,true);assert.equal(r.counted,false);assert.equal(r.helped,true);});
test('Same-second relevant teaching disqualifies by event order',()=>{const l=prepared(),p=show(l);expose(l,['force'],'lesson',at(1),id());assert.equal(answer(l,p).counted,false);});
test('Unrelated concept teaching does not disqualify',()=>{const l=prepared(),p=show(l);expose(l,['energy'],'lesson',at(1),id());assert.equal(answer(l,p).counted,true);});
test('Overlapping same-concept presentations preserve strict invalidation',()=>{const l=prepared(),a=show(l),b=show(l,1,'force-now-2');assert.equal(a.eligibility.canCount,true);assert.equal(b.eligibility.canCount,true);assert.equal(answer(l,a).counted,false);assert.equal(answer(l,b).counted,false);});
test('Most recent pending presentation can count, older cannot',()=>{const l=prepared(),a=show(l),b=show(l,1,'force-now-2');assert.equal(answer(l,b).counted,true);assert.equal(answer(l,a).counted,false);assert.equal(summary(l,at(1)).points,10);});
test('Counted wrong also consumes daily concept allowance',()=>{const l=prepared();assert.equal(answer(l,show(l),1,false).counted,true);assert.equal(show(l,1,'force-now-2').eligibility.canCount,false);});
test('Duplicate submit across serialized reload remains original',()=>{let l=prepared(),p=show(l);const r=answer(l,p,1,false);l=JSON.parse(JSON.stringify(l));const before=JSON.stringify(l);assert.deepEqual(answer(l,p,20,true,true),r);assert.equal(JSON.stringify(l),before);});
test('Feedback date restarts teaching and repeated-item clocks',()=>{const l=prepared(),p=show(l);answer(l,p,2);assert.equal(eligibility(l,byID('force-now-2'),true,at(3)-1000).canCount,false);assert.equal(eligibility(l,byID('force-now-2'),true,at(3)).canCount,true);assert.equal(eligibility(l,byID('force-later-1'),true,at(9)-1000).canCount,false);assert.equal(eligibility(l,byID('force-later-1'),true,at(9)).canCount,true);});
test('Exactly14 days not older, later older, no decay',()=>{const l=validSuccess();const slot=now=>summary(l,now).slots.find(s=>s.question==='force-later-1');assert.equal(slot(at(15)).older,false);assert.equal(slot(at(15)+1000).older,true);assert.equal(summary(l,at(500)).points,10);});
test('Practice and non-designated answers preserve zero score',()=>{for(const [q,review]of[['force-now-2',false],['force-now-1',true]]){const l=prepared(),p=show(l,1,q,review);assert.equal(answer(l,p).counted,false);assert.equal(l.receipts.length,1);}});
test('Selection prefers eligible unknown then incorrect',()=>{const l=prepared();answer(l,show(l),1);assert.equal(selectQuestion(l,questions,'force',at(8)).id,'force-now-2');answer(l,show(l,8,'force-now-2'),8,false);assert.equal(selectQuestion(l,questions,'force',at(15)).id,'force-now-2');});
test('Selection uses oldest correct once both are correct',()=>{const l=prepared();answer(l,show(l),1);answer(l,show(l,8,'force-now-2'),8);assert.equal(selectQuestion(l,questions,'force',at(15)).id,'force-later-1');});
test('Selection rotates away from skipped item',()=>{const l=freshLearning();assert.equal(selectQuestion(l,questions,'force',T).id,'force-later-1');show(l,0);assert.equal(selectQuestion(l,questions,'force',T).id,'force-now-1');});
test('Review reset preserves earlier-success fact',()=>{const l=prepared();answer(l,show(l,0,'force-now-1',false),0);answer(l,show(l,1,'force-now-2'),1,false);answer(l,show(l,2,'force-later-1'),2);assert.equal(reviewDue(l,'force'),at(5));});
test('First success after failure still uses one-day interval',()=>{const l=prepared();answer(l,show(l,0,'force-now-1',false),0,false);answer(l,show(l,1,'force-now-2'),1);assert.equal(reviewDue(l,'force'),at(2));});
test('No-help fresh reviews grow 1/3/7/14/30 days',()=>{const l=prepared();let p=show(l,0,'force-now-1',false);answer(l,p,0);assert.equal(reviewDue(l,'force'),at(1));for(const [day,q,interval] of [[1,'force-now-2',3],[4,'force-later-1',7],[11,'force-now-2',14],[25,'force-later-1',30]]){p=show(l,day,q);answer(l,p,day);assert.equal(reviewDue(l,'force'),at(day+interval));}});
test('Invalid choice and backwards clock do not mutate',()=>{const l=prepared(),p=show(l),before=JSON.stringify(l);assert.throws(()=>submit(l,byID(p.question),p.id,'INVALID',false,at(1)));assert.equal(JSON.stringify(l),before);assert.throws(()=>answer(l,p,0));assert.equal(JSON.stringify(l),before);});
test('Duplicate presentation intent mismatch rejected',()=>{const l=prepared(),p=show(l);assert.throws(()=>present(l,byID('force-now-2'),true,at(1),p.id));assert.throws(()=>present(l,byID(p.question),false,at(1),p.id));});
test('Malformed missing-presentation history rejected',()=>{const l=validSuccess();l.presentations=[];assert.equal(rejected(l),true);});
test('Malformed duplicate receipt ID rejected',()=>{const l=validSuccess();l.receipts.push(clone(l.receipts[0]));assert.equal(rejected(l),true);});
test('Malformed invalid presentation event index rejected',()=>{const l=validSuccess();l.presentations[0].exposureIndex=99;assert.equal(rejected(l),true);});
test('Malformed future answer-before-presentation time rejected',()=>{const l=validSuccess();l.receipts[0].at=T;assert.equal(rejected(l),true);});
test('Malformed mismatched question-event concept rejected',()=>{const l=validSuccess();l.exposures[l.presentations[0].exposureIndex].concept='energy';assert.equal(rejected(l),true);});
test('Malformed help event referencing missing presentation rejected',()=>{const l=validSuccess();l.exposures.push({id:'orphan',concept:'force',question:'force-now-2',presentation:'missing',kind:'help',at:at(1),version:VERSION});assert.equal(rejected(l),true);});
test('Malformed duplicate exposure ID rejected',()=>{const l=validSuccess();l.exposures.push(clone(l.exposures[0]));assert.equal(rejected(l),true);});
test('Malformed uncounted receipt with nonzero delta rejected',()=>{const l=validSuccess();l.receipts[0].counted=false;assert.equal(rejected(l),true);});
const files=['lib/learning.ts','app/api/action/route.ts','lib/store.ts'];const hashes=Object.fromEntries(files.map(f=>[f,crypto.createHash('sha256').update(fs.readFileSync(root+f)).digest('hex')]));
const report={at:new Date().toISOString(),tests:results.length,passed:results.filter(t=>t.pass).length,failed:results.filter(t=>!t.pass),hashes,results};

console.log(JSON.stringify({tests:report.tests,passed:report.passed,failed:report.failed,hashes},null,2));
process.exitCode=report.failed.length?1:0;
