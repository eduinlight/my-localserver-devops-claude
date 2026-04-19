import "dotenv/config";
import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  ListObjectsV2Command,
  DeleteObjectCommand,
} from "@aws-sdk/client-s3";

const {
  GARAGE_ENDPOINT,
  GARAGE_REGION,
  GARAGE_BUCKET,
  GARAGE_ACCESS_KEY,
  GARAGE_SECRET_KEY,
} = process.env;

for (const [k, v] of Object.entries({
  GARAGE_ENDPOINT,
  GARAGE_REGION,
  GARAGE_BUCKET,
  GARAGE_ACCESS_KEY,
  GARAGE_SECRET_KEY,
})) {
  if (!v) {
    console.error(`Missing env: ${k}`);
    process.exit(1);
  }
}

// Virtual-host style: SDK issues requests to <bucket>.s3.lan:3900.
// Garage parses the bucket from the subdomain because garage.toml sets root_domain = ".s3.lan".
const s3 = new S3Client({
  endpoint: GARAGE_ENDPOINT,
  region: GARAGE_REGION,
  credentials: {
    accessKeyId: GARAGE_ACCESS_KEY,
    secretAccessKey: GARAGE_SECRET_KEY,
  },
  forcePathStyle: false,
});

const key = "hello.json";
const payload = { hello: "garage", at: new Date().toISOString() };

async function main() {
  console.log(`→ PUT  s3://${GARAGE_BUCKET}/${key}`);
  await s3.send(
    new PutObjectCommand({
      Bucket: GARAGE_BUCKET,
      Key: key,
      Body: JSON.stringify(payload),
      ContentType: "application/json",
    }),
  );

  console.log(`→ GET  s3://${GARAGE_BUCKET}/${key}`);
  const got = await s3.send(
    new GetObjectCommand({ Bucket: GARAGE_BUCKET, Key: key }),
  );
  const body = await got.Body.transformToString();
  console.log(`  body: ${body}`);

  console.log(`→ LIST s3://${GARAGE_BUCKET}/`);
  const listed = await s3.send(
    new ListObjectsV2Command({ Bucket: GARAGE_BUCKET }),
  );
  for (const o of listed.Contents ?? []) {
    console.log(`  - ${o.Key} (${o.Size} B)`);
  }

  console.log(`→ DEL  s3://${GARAGE_BUCKET}/${key}`);
  await s3.send(
    new DeleteObjectCommand({ Bucket: GARAGE_BUCKET, Key: key }),
  );

  console.log("✅ ok");
}

main().catch((err) => {
  console.error("❌ failed:", err);
  process.exit(1);
});
