using UnityEngine;

public interface Skill
{
    float GetRange();
    int CurrentCooldown();
    void ReduceCooldown(int number);
    void useSkill(Vector3 targetPosition, GameObject wielder);
    void prepareSkill(Vector3 fromPosition, GameObject wielder);
}
