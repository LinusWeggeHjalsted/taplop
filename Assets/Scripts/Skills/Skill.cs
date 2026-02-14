using UnityEngine;

public interface Skill
{
    int skillBarPosition { get; set; }
    string GetSkillName();
    string GetSkillType();
    string GetDescription();
    float GetRange();
    float GetRadius();
    float GetDistance();
    int GetSkillDuration();
    int GetStunDuration();
    Sprite GetSprite();
    int GetCooldown();
    int EnemyPriority(Vector3 fromPosition, GameObject enemy);
    Vector3 EnemySelectTarget(Vector3 fromPosition, GameObject enemy);
    void UseSkill(Vector3 targetPosition, GameObject wielder);
    void PrepareSkill(Vector3 fromPosition, GameObject wielder);
}
