import { redirect } from "next/navigation";

// The marketing landing page has been retired — / now goes straight to the game.
export default function HomePage(): never {
  redirect("/race");
}

