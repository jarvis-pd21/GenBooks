import { getChatGPTUser, chatGPTSignInPath, chatGPTSignOutPath } from "./chatgpt-auth";
import GenBooks from "./genbooks";
export const dynamic="force-dynamic";
export default async function Home(){const user=await getChatGPTUser();return <GenBooks user={user?{scope:user.userId,name:user.fullName||user.email}:null} signIn={chatGPTSignInPath("/")} signOut={chatGPTSignOutPath("/")}/>}
