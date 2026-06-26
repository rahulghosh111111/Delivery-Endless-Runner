<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('game_sessions', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
            $table->timestamp('starts_at');
            $table->timestamp('ends_at');
            $table->unsignedInteger('duration_seconds')->default(1800);

            // Last known client-reported state (kept for resilience / resume,
            // validated against plausibility on every sync — see controller).
            $table->unsignedInteger('score')->default(0);
            $table->unsignedInteger('coins')->default(0);
            $table->double('distance')->default(0);

            $table->unsignedInteger('reward_coins')->default(0); // credited to wallet
            $table->enum('status', ['active', 'completed', 'abandoned'])->default('active');

            $table->timestamps();

            $table->index(['user_id', 'status']);
        });

        // Per-user best score, kept separate so leaderboard/profile queries
        // don't have to scan the (potentially large) sessions table.
        Schema::create('game_best_scores', function (Blueprint $table) {
            $table->foreignId('user_id')->primary()->constrained('users')->cascadeOnDelete();
            $table->unsignedInteger('best_score')->default(0);
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('game_best_scores');
        Schema::dropIfExists('game_sessions');
    }
};
