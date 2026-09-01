export type Address = `0x${string}`;

export type Deployment = {
  vault: Address;
  controller: Address;
  hook: Address;
  hookFactory: Address;
  executor: Address;
  swapRouter: Address;
  token0: Address;
  token1: Address;
};

export type Roles = {
  deployer: Address;
  ada: Address;
  bao: Address;
  jit: Address;
  trader: Address;
};

export type StepRecord = {
  stepId: string;
  actor: keyof Roles;
  transactionHash: Address;
  blockNumber: string;
  eventSummary: string;
  metadata?: Record<string, string>;
  createdAt: string;
};

export type DemoRun = {
  id: string;
  title: string;
  deployment: Deployment;
  rsc: Address;
  rvmId: Address;
  roles: Roles;
  createdAt: string;
  steps: StepRecord[];
};
