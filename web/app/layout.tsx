import type { Metadata } from "next";
import "./globals.css";
export const metadata: Metadata = {title:"GenBooks — Read, understand, remember",description:"A personal library built to increase retained knowledge and skills. Read, practice and keep your learning in sync.",icons:{icon:"/favicon.svg",shortcut:"/favicon.svg"}};
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="en"><body>{children}</body></html>}
