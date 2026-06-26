<?php
namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class GameBestScore extends Model
{
    protected $primaryKey = 'user_id';
    public $incrementing = false;

    protected $fillable = ['user_id', 'best_score'];
}
