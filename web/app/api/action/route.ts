import {json,user,input,failure,id,text,ApiError} from '@/lib/api';
import {loadState,mutateState,ownedBookObject} from '@/lib/store';
import {course,questions,catalogBook} from '@/lib/catalog';
import {expose,present,submit,selectQuestion,summary} from '@/lib/learning';
import type {Book} from '@/lib/models';
export const dynamic='force-dynamic';
export async function POST(request:Request){try{const owner=await user(request);const data=await input(request);const operation=text(data.type,30);const requestId=id(data.id);const requestedAt=Date.now();
 let now=Math.floor(requestedAt/1000)*1000;
 let book:Book|undefined;
 if(['position','note'].includes(operation)){const bookId=id(data.bookId);book=catalogBook(bookId);if(!book){const {state}=await loadState(owner);const meta=state.books.find(b=>b.id===bookId);if(!meta)throw new ApiError('This book is not in your library.',404);const object=await ownedBookObject(owner,meta.key);if(!object)throw new ApiError('Book content is temporarily unavailable.',503);book=await object.json<Book>();}if(!Number.isInteger(data.chapter)||data.chapter<0||data.chapter>=book.chapters.length)throw new ApiError('Choose an available chapter.');if(data.block&&!book.chapters[data.chapter].blocks.some(b=>b.id===data.block))throw new ApiError('This passage is not in the chapter.');}
 const result=await mutateState(owner,state=>{
 now=Math.floor(Date.now()/1000)*1000;
 const l=state.learning;
 if(operation==='answer'){const p=l.presentations.find(p=>p.id===id(data.presentation));const q=questions.find(q=>q.id===p?.question);if(!q)throw new ApiError('Start a practice question first.');return submit(l,q,p!.id,text(data.choice,10),data.helped===true,now);}
 if(operation==='present'){const existing=l.presentations.find(p=>p.id===requestId);if(existing){if((data.question&&existing.question!==data.question)||(data.concept&&existing.concept!==data.concept)||existing.review!==(data.review===true))throw new ApiError('That question request was already used for a different practice session.',409);return existing;}const q=data.question?questions.find(q=>q.id===id(data.question)):selectQuestion(l,questions,id(data.concept),now);if(!q)throw new ApiError('No question is available for that concept.');return present(l,q,data.review===true,now,requestId);}
 if(state.mutationIds.includes(requestId)||l.exposures.some(e=>e.id.startsWith(requestId+':'))||l.feedback.some(f=>f.id===requestId))return {saved:true};
 switch(operation){
 case 'lesson':case 'finish':{const lesson=course.lessons.find(l=>l.id===id(data.lesson));if(!lesson)throw new ApiError('Unknown reading.');expose(l,lesson.conceptIds,'lesson',now,requestId);l.lastLesson=lesson.id;if(operation==='finish'&&!l.completed.includes(lesson.id))l.completed.push(lesson.id);break;}
 case 'help':{const p=l.presentations.find(p=>p.id===id(data.presentation));if(!p)throw new ApiError('Start a question before opening its explanation.');if(!l.receipts.some(r=>r.id===p.id))expose(l,[p.concept],'help',now,requestId,p.question,p.id);break;}
 case 'learned':{const concept=id(data.concept);if(!course.concepts.some(c=>c.id===concept))throw new ApiError('Unknown concept.');if(l.learned[concept]===undefined)l.learned[concept]=now;break;}
 case 'feedback':{const lesson=id(data.lesson);if(!course.lessons.some(l=>l.id===lesson)||!['enjoyable','neutral','tooDemanding'].includes(data.experience))throw new ApiError('Choose a reading and feedback.');l.feedback.push({id:requestId,lesson,experience:data.experience,at:now});break;}
 case 'position':{if(!book)throw new ApiError('Book unavailable.');if((state.positions[book.id]?.updated??0)<=requestedAt)state.positions[book.id]={chapter:data.chapter,block:typeof data.block==='string'?data.block:'',updated:requestedAt};break;}
 case 'note':{if(!book)throw new ApiError('Book unavailable.');const noteId=id(data.noteId);const existing=state.notes.find(n=>n.id===noteId);if((existing&&existing.version!==data.version)||(!existing&&data.version!==0))throw new ApiError('This note changed in another browser. Your draft is preserved; reload the saved note before replacing it.',409);if(!existing&&state.notes.length>=1000)throw new ApiError('Your account currently supports 1,000 notes. Export your notes before removing any.');const note={id:noteId,bookId:book.id,bookTitle:book.title,chapter:data.chapter,chapterTitle:book.chapters[data.chapter].title,block:typeof data.block==='string'?data.block:'',quote:text(data.quote??'',8000,true),body:text(data.body??'',10000,true),kind:data.kind==='word'?'word' as const:'note' as const,known:data.known===true,updated:now,version:(existing?.version??0)+1};if(!note.quote&&!note.body)throw new ApiError('Write a note or choose a passage.');if(existing)state.notes=state.notes.map(n=>n.id===noteId?note:n);else state.notes.push(note);break;}
 case 'delete-note':{const n=state.notes.find(n=>n.id===id(data.noteId));if(n&&n.version!==data.version)throw new ApiError('This note changed in another browser. Refresh it before deleting.',409);state.notes=state.notes.filter(n=>n.id!==data.noteId);break;}
 case 'preferences':{if(![5,10,20].includes(data.minutes))throw new ApiError('Choose 5, 10 or 20 minutes.');state.preferences.sessionMinutes=data.minutes;break;}
 default:throw new ApiError('Unsupported action.');
 }
 state.mutationIds.push(requestId);state.mutationIds=state.mutationIds.slice(-512);return {saved:true};
 });return json({...result,account:owner,score:summary(result.state.learning,now),serverTime:now});}catch(e){return failure(e)}}
