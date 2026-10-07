import {user,failure} from '@/lib/api';
import {loadState,ownedBookObject} from '@/lib/store';
export const dynamic='force-dynamic';
export async function GET(request:Request){try{
 const owner=await user(request);const {state}=await loadState(owner);const encoder=new TextEncoder();
 // One book at a time keeps export memory bounded even for a full library.
 const chunks=async function*(){yield JSON.stringify({format:'genbooks-web-export',version:1,exportedAt:new Date().toISOString(),state}).slice(0,-1)+',"importedBooks":[';
 for(let i=0;i<state.books.length;i++){const object=await ownedBookObject(owner,state.books[i].key);yield (i?',':'')+await object.text();}yield ']}';};
 const iterator=chunks();const stream=new ReadableStream<Uint8Array>({async pull(controller){try{const next=await iterator.next();if(next.done)controller.close();else controller.enqueue(encoder.encode(next.value));}catch(e){controller.error(e);}},async cancel(){await iterator.return();}});
 return new Response(stream,{headers:{'Content-Type':'application/json','Content-Disposition':'attachment; filename="genbooks-library.json"','Cache-Control':'private, no-store','Vary':'Cookie','X-Content-Type-Options':'nosniff'}});
 }catch(e){return failure(e)}}
