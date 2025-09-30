using UnityEngine;

public interface Skill
{
    string GetDescription();
    float GetRange();
    int CurrentCooldown();
    void ReduceCooldown(int number);
    int EnemyPriority(Vector3 fromPosition);
    void useSkill(Vector3 targetPosition, GameObject wielder);
    void prepareSkill(Vector3 fromPosition, GameObject wielder);
}
