import course from '@/content/physics.json';
import argentina from '@/content/argentina.json';
import type {Book} from './models';
import type {Question} from './learning';
export {course};
export const questions:Question[]=[...course.delayedReview.checks,...course.lessons.flatMap(l=>l.checks)];
export const books:Book[]=[{id:'physics',title:course.title,author:'GenBooks',description:course.subtitle,kind:'physics',chapters:course.lessons.map(l=>({id:l.id,title:l.title,lessonId:l.id,blocks:l.blocks.map(b=>({id:b.id,kind:b.kind,text:b.text}))}))},{id:'argentina',title:argentina.title,author:'GenBooks',description:'An original illustrative manuscript. Opening chapters are prose; later chapters are outlines. Not an independently verified history textbook.',kind:'sample',chapters:argentina.chapters.map(c=>{const r=c.revisions.find(r=>r.id===c.activeRevisionId)??c.revisions.at(-1)!;return {id:c.id,title:c.title,blocks:r.blocks.map(b=>({id:b.id,kind:b.kind,text:b.text}))}})}];
export const catalogBook=(id:string)=>books.find(b=>b.id===id);
