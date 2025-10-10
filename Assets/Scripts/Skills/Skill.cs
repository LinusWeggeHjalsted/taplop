using UnityEngine;

public interface Skill
{
    string GetSkillType();
    string GetDescription();
    float GetRange();
    Sprite GetSprite();
    int GetCooldown();
    int CurrentCooldown();
    void ReduceCooldown(int number);
    int EnemyPriority(Vector3 fromPosition);
    Vector3 EnemySelectTarget(Vector3 fromPosition);
    void UseSkill(Vector3 targetPosition, GameObject wielder);
    void PrepareSkill(Vector3 fromPosition, GameObject wielder);
}
