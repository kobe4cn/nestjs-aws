import { MigrationInterface, QueryRunner } from "typeorm";

export class Emailverified1792982283506 implements MigrationInterface {
    name = 'Emailverified1792982283506'

    public async up(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`ALTER TABLE "user" ADD "emailVerified" boolean NOT NULL DEFAULT false`);
    }

    public async down(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`ALTER TABLE "user" DROP COLUMN "emailVerified"`);
    }

}
