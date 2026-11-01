import { MigrationInterface, QueryRunner } from "typeorm";

export class Apikey11793089100676 implements MigrationInterface {
    name = 'Apikey11793089100676'

    public async up(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`ALTER TABLE "api_keys" DROP CONSTRAINT "PK_5c8a79801b44bd27b79228e1dad"`);
        await queryRunner.query(`ALTER TABLE "api_keys" DROP COLUMN "id"`);
        await queryRunner.query(`ALTER TABLE "api_keys" ADD "id" text NOT NULL`);
        await queryRunner.query(`ALTER TABLE "api_keys" ADD CONSTRAINT "PK_5c8a79801b44bd27b79228e1dad" PRIMARY KEY ("id")`);
    }

    public async down(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`ALTER TABLE "api_keys" DROP CONSTRAINT "PK_5c8a79801b44bd27b79228e1dad"`);
        await queryRunner.query(`ALTER TABLE "api_keys" DROP COLUMN "id"`);
        await queryRunner.query(`ALTER TABLE "api_keys" ADD "id" SERIAL NOT NULL`);
        await queryRunner.query(`ALTER TABLE "api_keys" ADD CONSTRAINT "PK_5c8a79801b44bd27b79228e1dad" PRIMARY KEY ("id")`);
    }

}
