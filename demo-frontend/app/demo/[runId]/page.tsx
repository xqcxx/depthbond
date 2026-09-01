import { Walkthrough } from "@/components/walkthrough";

export default async function DemoPage({ params }: { params: Promise<{ runId: string }> }) {
  const { runId } = await params;
  return <Walkthrough runId={runId} />;
}
