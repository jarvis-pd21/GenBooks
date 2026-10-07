import type {Learning} from './learning';
export type Block={id:string;kind:string;text:string};
export type Chapter={id:string;title:string;blocks:Block[];lessonId?:string};
export type Book={id:string;title:string;author:string;description:string;kind:'physics'|'sample'|'imported';chapters:Chapter[]};
export type SavedBook={id:string;title:string;author:string;chapters:number;key:string;added:number;bytes:number};
export type Position={chapter:number;block:string;updated:number};
export type Note={id:string;bookId:string;bookTitle:string;chapter:number;chapterTitle:string;block:string;quote:string;body:string;kind:'note'|'word';known:boolean;version:number;updated:number};
export type AppState={schema:1;learning:Learning;books:SavedBook[];positions:Record<string,Position>;notes:Note[];mutationIds:string[];preferences:{sessionMinutes:number}};
/** Validate stored account records before any renderer or mutation uses them. */
export function validRecords(s:AppState):boolean{
 const str=(x:unknown,max=30000)=>typeof x==='string'&&x.length<=max;
 const integer=(x:unknown)=>typeof x==='number'&&Number.isSafeInteger(x)&&x>=0;
 const object=(x:unknown)=>!!x&&typeof x==='object'&&!Array.isArray(x);
 if(!Array.isArray(s.notes)||s.notes.length>1000||!s.notes.every(n=>object(n)&&str(n.id,100)&&str(n.bookId,100)&&str(n.bookTitle,200)&&str(n.chapterTitle,200)&&integer(n.chapter)&&str(n.block,300)&&str(n.quote,8000)&&str(n.body,10000)&&['note','word'].includes(n.kind)&&typeof n.known==='boolean'&&integer(n.version)&&n.version>0&&integer(n.updated)))return false;
 if(!Array.isArray(s.books)||s.books.length>40||!s.books.every(b=>object(b)&&str(b.id,100)&&str(b.title,200)&&str(b.author,200)&&integer(b.chapters)&&b.chapters>0&&b.chapters<=100&&str(b.key,400)&&integer(b.added)&&integer(b.bytes)))return false;
 if(!object(s.positions)||!Object.values(s.positions).every(p=>object(p)&&integer(p.chapter)&&str(p.block,300)&&integer(p.updated)))return false;
 return new Set(s.notes.map(n=>n.id)).size===s.notes.length&&new Set(s.books.map(b=>b.id)).size===s.books.length&&Array.isArray(s.mutationIds)&&s.mutationIds.every(x=>str(x,100))&&object(s.preferences)&&[5,10,20].includes(s.preferences.sessionMinutes);
}
