export class LearningError extends Error{}
/** Pure score policy. Time is supplied by the server; no browser clock awards points. */
export const DAY=86_400_000;
export const VERSION='physics-foundations-v1';
export const SLOTS:Record<string,string[]>={models:['model-later-1','model-now-2'],force:['force-later-1','force-now-2'],momentum:['momentum-later-1','momentum-now-2'],energy:['energy-later-1','energy-now-2'],entropy:['entropy-later-1','entropy-now-2']};
export type Question={id:string;conceptId:string;prompt:string;choices:{id:string;text:string}[];correctChoiceId:string;explanation:string;sourceIds:string[]};
export type Eligibility={canCount:boolean;reason:string;nextEligibleAt?:number};
export type Exposure={id:string;concept:string;question?:string;presentation?:string;kind:'lesson'|'question'|'answer'|'help';at:number;version:string};
export type Presentation={id:string;concept:string;question:string;at:number;version:string;review:boolean;eligibility:Eligibility;exposureIndex:number};
export type Receipt={id:string;concept:string;question:string;at:number;version:string;correct:boolean;helped:boolean;counted:boolean;delta:number;reason:string;choice:string;review:boolean};
export type Learning={version:1;completed:string[];lastLesson?:string;learned:Record<string,number>;feedback:{id:string;lesson:string;experience:string;at:number}[];exposures:Exposure[];presentations:Presentation[];receipts:Receipt[]};
export function freshLearning():Learning{return {version:1,completed:[],learned:{},feedback:[],exposures:[],presentations:[],receipts:[]}}
export function summary(l:Learning,now:number){
 const slots=Object.entries(SLOTS).flatMap(([concept,qs])=>qs.map(question=>{const receipts=l.receipts.filter(r=>r.counted&&r.version===VERSION&&r.question===question&&r.concept===concept);let latest:Receipt|undefined;for(const r of receipts)if(!latest||r.at>=latest.at)latest=r;return {concept,question,status:latest?(latest.correct?'correct':'incorrect'):'unknown',at:latest?.at,older:!!latest&&now-latest.at>14*DAY,points:latest?.correct?10:0}}));
 return {points:slots.reduce((n,s)=>n+s.points,0),checked:slots.filter(s=>s.status!=='unknown').length,slots};
}
export function eligibility(l:Learning,q:Question,review:boolean,now:number):Eligibility{
 if(!SLOTS[q.conceptId]?.includes(q.id))return {canCount:false,reason:'Practice question: this question is not one of the ten score checks.'};
 if(!review)return {canCount:false,reason:'Practice after reading. Return later through a concept review for a score check.'};
 const teaching=l.exposures.filter(e=>e.version===VERSION&&e.concept===q.conceptId&&e.kind!=='question');
 if(!teaching.length)return {canCount:false,reason:'Start with a reading for this concept, then return at least 24 hours later.'};
 const lastTeaching=Math.max(...teaching.map(e=>e.at));
 const questions=l.exposures.filter(e=>e.version===VERSION&&e.question===q.id);
 const counted=l.receipts.filter(r=>r.version===VERSION&&r.concept===q.conceptId&&r.counted);
 const ready=Math.max(lastTeaching+DAY,questions.length?Math.max(...questions.map(e=>e.at))+7*DAY:0,counted.length?Math.max(...counted.map(r=>r.at))+DAY:0);
 if(now<ready)return {canCount:false,reason:'Practice only: wait 24 hours after teaching or a counted check, and seven days after seeing this same question.',nextEligibleAt:ready};
 return {canCount:true,reason:'Eligible for your check score: answer without help before opening more material for this concept.'};
}
export function expose(l:Learning,concepts:string[],kind:Exposure['kind'],now:number,id:string,question?:string,presentation?:string){
 for(const concept of concepts)l.exposures.push({id:id+':'+concept,concept,kind,at:now,question,presentation,version:VERSION});
}
export function present(l:Learning,q:Question,review:boolean,now:number,id:string){
 const existing=l.presentations.find(p=>p.id===id);if(existing){if(existing.question!==q.id||existing.review!==review)throw new LearningError('This request was already used for a different question.');return existing;}
 const p:Presentation={id,concept:q.conceptId,question:q.id,at:now,version:VERSION,review,eligibility:eligibility(l,q,review,now),exposureIndex:l.exposures.length};
 l.presentations.push(p);expose(l,[q.conceptId],'question',now,id,q.id,id);return p;
}
export function submit(l:Learning,q:Question,presentationId:string,choice:string,helped:boolean,now:number):Receipt{
 const previous=l.receipts.find(r=>r.id===presentationId);if(previous)return previous;
 const p=l.presentations.find(p=>p.id===presentationId);if(!p||p.question!==q.id||p.concept!==q.conceptId||p.version!==VERSION)throw new LearningError('This question session is unavailable. Start a new practice question.');
 if(!q.choices.some(c=>c.id===choice))throw new LearningError('Choose one of the available answers.');
 if(now<p.at||l.exposures.slice(p.exposureIndex).some(e=>e.at>now))throw new LearningError('The saved event times are inconsistent. Your previous evidence has been preserved.');
 const after=l.exposures.slice(p.exposureIndex).filter(e=>e.concept===q.conceptId);
 const help=helped||after.some(e=>e.kind==='help'&&e.presentation===p.id)||after.some(e=>e.kind!=='question');
 const other=after.some(e=>e.kind==='question'&&e.presentation!==p.id);
 const recent=l.receipts.some(r=>r.counted&&r.concept===q.conceptId&&r.version===VERSION&&now-r.at<DAY);
 const counted=p.eligibility.canCount&&!help&&!other&&!recent;
 const correct=q.correctChoiceId===choice;
 const old=summary(l,now).slots.find(s=>s.question===q.id)?.points??0;
 const reason=counted?(correct?'This eligible correct answer contributes 10 points for this question.':'This eligible answer is incorrect; this question now contributes 0 points.'):(help?'Practice saved with help. Reading or an explanation was opened after this question began.':other?'Practice saved. Another question for this concept was opened after this one.':recent?'Practice saved. Only one check per concept can count in 24 hours.':p.eligibility.reason);
 const r:Receipt={id:p.id,concept:q.conceptId,question:q.id,at:now,version:VERSION,correct,helped:help,counted,delta:counted?(correct?10:0)-old:0,reason,choice,review:p.review};
 l.receipts.push(r);expose(l,[q.conceptId],'answer',now,p.id+':answer',q.id,p.id);return r;
}
export function selectQuestion(l:Learning,questions:Question[],concept:string,now:number){
 const candidates=questions.filter(q=>q.conceptId===concept);const score=summary(l,now);
 const eligible=candidates.filter(q=>eligibility(l,q,true,now).canCount);
 if(eligible.length)return eligible.sort((a,b)=>{const sa=score.slots.find(s=>s.question===a.id)!;const sb=score.slots.find(s=>s.question===b.id)!;const rank=(s:typeof sa)=>s.status==='unknown'?0:s.status==='incorrect'?1:2;return rank(sa)-rank(sb)||(sa.at??0)-(sb.at??0)})[0];
 const last=(id:string)=>Math.max(0,...l.exposures.filter(e=>e.question===id).map(e=>e.at));
 return candidates.sort((a,b)=>last(a.id)-last(b.id))[0];
}
export function reviewDue(l:Learning,concept:string):number|undefined{
 const attempts=l.receipts.filter(r=>r.concept===concept).map((r,i)=>({...r,i})).sort((a,b)=>a.at-b.at||a.i-b.i);
 const last=attempts.at(-1);const learned=l.learned[concept];
 if(learned!==undefined&&(!last||learned>=last.at))return learned+DAY;
 if(!last)return undefined;
 let chain=0;let success=false;let prior:Receipt|undefined;
 for(const r of attempts){if(!r.correct||r.helped){chain=0;}else{if(success&&r.review&&prior&&r.question!==prior.question&&r.at-prior.at>=DAY)chain=Math.min(chain+1,4);success=true;}prior=r;}
 return last.at+[1,3,7,14,30][chain]*DAY;
}

/** Reject unreadable or internally inconsistent persisted evidence; never reset it. */
export function validateLearning(value:unknown):value is Learning{
 if(!value||typeof value!=='object')return false;const l=value as Learning;
 if(l.version!==1||!Array.isArray(l.completed)||!l.completed.every(x=>typeof x==='string')||!l.learned||typeof l.learned!=='object'||!Array.isArray(l.feedback)||!Array.isArray(l.exposures)||!Array.isArray(l.presentations)||!Array.isArray(l.receipts))return false;
 const date=(v:unknown)=>typeof v==='number'&&Number.isSafeInteger(v)&&v>=0;
 const str=(v:unknown)=>typeof v==='string'&&v.length>0;
 if(!Object.values(l.learned).every(date)||!l.feedback.every(f=>f&&str(f.id)&&str(f.lesson)&&['enjoyable','neutral','tooDemanding'].includes(f.experience)&&date(f.at)))return false;
 if(!l.exposures.every(e=>e&&str(e.id)&&str(e.concept)&&str(e.version)&&['lesson','question','answer','help'].includes(e.kind)&&date(e.at)))return false;
 if(new Set(l.exposures.map(e=>e.id)).size!==l.exposures.length)return false;
 if(new Set(l.presentations.map(p=>p.id)).size!==l.presentations.length||new Set(l.receipts.map(r=>r.id)).size!==l.receipts.length)return false;
 if(!l.presentations.every(p=>p&&str(p.id)&&str(p.question)&&str(p.concept)&&str(p.version)&&date(p.at)&&typeof p.review==='boolean'&&p.eligibility&&typeof p.eligibility.canCount==='boolean'&&str(p.eligibility.reason)&&Number.isSafeInteger(p.exposureIndex)&&p.exposureIndex>=0&&l.exposures[p.exposureIndex]?.presentation===p.id&&l.exposures[p.exposureIndex]?.kind==='question'&&l.exposures[p.exposureIndex]?.question===p.question&&l.exposures[p.exposureIndex]?.concept===p.concept&&l.exposures[p.exposureIndex]?.version===p.version&&l.exposures[p.exposureIndex]?.at===p.at))return false;
 if(!l.exposures.every(e=>e.kind==='lesson'||l.presentations.some(p=>p.id===e.presentation&&p.question===e.question&&p.concept===e.concept&&p.version===e.version&&e.at>=p.at)))return false;
 return l.receipts.every(r=>{if(!r||!str(r.id)||!str(r.question)||!str(r.concept)||!str(r.version)||!date(r.at)||typeof r.correct!=='boolean'||typeof r.helped!=='boolean'||typeof r.counted!=='boolean'||typeof r.review!=='boolean'||![-10,0,10].includes(r.delta)||(!r.counted&&r.delta!==0)||!str(r.choice)||!str(r.reason))return false;const p=l.presentations.find(p=>p.id===r.id);return !!p&&p.question===r.question&&p.concept===r.concept&&p.version===r.version&&r.at>=p.at&&(!r.counted||(p.eligibility.canCount&&p.review&&!r.helped&&SLOTS[r.concept]?.includes(r.question)))&&l.exposures.some(e=>e.presentation===r.id&&e.question===r.question&&e.kind==='answer');});
}
