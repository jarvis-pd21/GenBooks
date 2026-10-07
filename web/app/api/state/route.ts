import {json,user,failure} from '@/lib/api';
import {loadState} from '@/lib/store';
export const dynamic='force-dynamic';
export async function GET(){try{const owner=await user();const data=await loadState(owner);const {exists,...out}=data;return json({...out,account:owner,serverTime:Date.now()})}catch(e){return failure(e)}}
