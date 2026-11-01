import { MigrationInterface, QueryRunner } from "typeorm";

export class Password1792978752327 implements MigrationInterface {
    name = 'Password1792978752327'

    public async up(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`ALTER TABLE "user" ADD "hashedPassword" character varying`);
    }

    public async down(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`ALTER TABLE "user" DROP COLUMN "hashedPassword"`);
    }

}
