using UnityEngine;

public class NoSkillScript : MonoBehaviour, Skill
{
    private int currentCooldown = 0;

    public float GetRange()
    {
        return 0;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
    }

    public void useSkill(Vector3 targetPosition, GameObject wielder)
    {
        Debug.Log("no skill equipped in this slot");
    }

    public void prepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        Debug.Log("no skill equipped in this slot");
    }

}
