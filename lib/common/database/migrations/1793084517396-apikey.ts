import { MigrationInterface, QueryRunner } from "typeorm";

export class Apikey1793084517396 implements MigrationInterface {
    name = 'Apikey1793084517396'

    public async up(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`CREATE TABLE "api_keys" ("id" SERIAL NOT NULL, "user_id" text NOT NULL, "hash" text NOT NULL, "create_at" TIMESTAMP WITH TIME ZONE NOT NULL, "expires_at" TIMESTAMP WITH TIME ZONE NOT NULL, CONSTRAINT "PK_5c8a79801b44bd27b79228e1dad" PRIMARY KEY ("id"))`);
        await queryRunner.query(`CREATE INDEX "api_keys_user_id_idx" ON "api_keys"  ("user_id") `);
    }

    public async down(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`DROP INDEX "public"."api_keys_user_id_idx"`);
        await queryRunner.query(`DROP TABLE "api_keys"`);
    }

}
