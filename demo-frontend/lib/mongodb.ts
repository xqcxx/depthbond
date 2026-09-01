import { Db, MongoClient } from "mongodb";

const databaseName = process.env.MONGODB_DB ?? "depthbond_demo";

const globalForMongo = globalThis as typeof globalThis & { mongoClient?: Promise<MongoClient> };

export async function db(): Promise<Db> {
  const uri = process.env.MONGODB_URI;
  if (!uri) throw new Error("MONGODB_URI is required. Add it to demo-frontend/.env.local.");
  const client = globalForMongo.mongoClient ?? new MongoClient(uri).connect();
  if (process.env.NODE_ENV !== "production") globalForMongo.mongoClient = client;
  return (await client).db(databaseName);
}
