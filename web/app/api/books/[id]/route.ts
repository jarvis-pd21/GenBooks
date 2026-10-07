import {json,user,failure,id,ApiError} from '@/lib/api';
import {loadState,ownedBookObject} from '@/lib/store';
export const dynamic='force-dynamic';
export async function GET(_request:Request,{params}:{params:Promise<{id:string}>}){try{const owner=await user(_request);const bookId=id((await params).id);const {state}=await loadState(owner);const book=state.books.find(b=>b.id===bookId);if(!book)throw new ApiError('Book not found in your library.',404);const object=await ownedBookObject(owner,book.key);if(!object)throw new ApiError('Book content is temporarily unavailable.',503);return json(await object.json())}catch(e){return failure(e)}}
