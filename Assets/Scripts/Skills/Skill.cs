using UnityEngine;

public interface Skill
{
    string GetSkillName();
    string GetSkillType();
    string GetDescription();
    float GetRange();
    int GetDuration();
    Sprite GetSprite();
    int GetCooldown();
    int CurrentCooldown();
    void ReduceCooldown(int number);
    int EnemyPriority(Vector3 fromPosition, GameObject enemy);
    Vector3 EnemySelectTarget(Vector3 fromPosition, GameObject enemy);
    void UseSkill(Vector3 targetPosition, GameObject wielder);
    void PrepareSkill(Vector3 fromPosition, GameObject wielder);
}
